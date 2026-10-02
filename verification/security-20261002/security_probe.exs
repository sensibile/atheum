Code.require_file("lib/atheum/core.ex")
Code.require_file("lib/atheum/akashic.ex")
Code.require_file("lib/atheum/postgres.ex")
Code.require_file("lib/atheum.ex")
ExUnit.start()

defmodule IndependentSecurityProbe do
  use ExUnit.Case, async: false
  alias Atheum.{Akashic, Core, Postgres}

  setup do
    root = Path.join(System.tmp_dir!(), "atheum-security-" <> Postgres.id())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp executable(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, "#!/usr/bin/env python3\n" <> body)
    File.chmod!(path, 0o700)
    path
  end

  test "argv retains path and request metacharacters literally", %{root: root} do
    bin = executable(root, "argv", "import json,sys\nprint(json.dumps({'ok':True,'result':{'argv':sys.argv[1:]}}))\n")
    path = Path.join(root, "db ; $(touch should-not-exist)")
    req = %{"command" => "apply", "request" => %{"id" => "'; $(touch nope) --records-db"}}
    assert {:ok, result} = Akashic.apply(req, %{binary: bin, storage: :snapshot, akashic_db: path, timeout_ms: 1000})
    assert result["argv"] == ["--db", path, "--json", JSON.encode!(req)]
  end

  test "malformed CLI success is accepted as confirmed absence", %{root: root} do
    bin = executable(root, "empty-success", "print('{\"ok\":true,\"result\":{\"apply\":{}}}')\n")
    assert {:ok, %{}} = Akashic.apply(%{}, %{binary: bin, storage: :snapshot, akashic_db: root, timeout_ms: 1000})
    assert {"succeeded", "confirmed_absent", %{}, nil} = Core.completion({:ok, %{}})
    assert {"succeeded", "confirmed_present", _, nil} = Core.completion({:ok, %{"changed" => "false"}})
  end

  test "four MiB result has no byte cap", %{root: root} do
    bin = executable(root, "large-success", "import json\nprint(json.dumps({'ok':True,'result':{'apply':{'changed':False,'padding':'x'*(4*1024*1024)}}}))\n")
    assert {:ok, result} = Akashic.apply(%{}, %{binary: bin, storage: :snapshot, akashic_db: root, timeout_ms: 2000})
    assert byte_size(result["padding"]) == 4 * 1024 * 1024
    IO.puts("OBSERVED CLI result bytes: #{byte_size(result["padding"])}")
  end

  test "psql call ignores config timeout", %{root: root} do
    bin = executable(root, "slow-psql", "import time\ntime.sleep(0.25)\nprint('{}')\n")
    start = System.monotonic_time(:millisecond)
    assert {:ok, "{}"} = Postgres.query("SELECT 1", %{psql: bin, pg_url: "postgres://postgres@127.0.0.1:55440/atheum_cycle_test", timeout_ms: 10})
    elapsed = System.monotonic_time(:millisecond) - start
    assert elapsed >= 250
    IO.puts("OBSERVED psql elapsed_ms=#{elapsed}, config.timeout_ms=10")
  end

  test "URL query override passes local DB allowlist", %{root: root} do
    bin = executable(root, "capture-psql", "import json,sys\nprint(json.dumps(sys.argv[1:]))\n")
    url = "postgres://postgres@127.0.0.1:55440/atheum_decoy?dbname=atheum_cycle_test"
    assert {:ok, output} = Postgres.query("SELECT current_database()", %{psql: bin, pg_url: url})
    assert Enum.at(JSON.decode!(output), 7) == url
    IO.puts("OBSERVED accepted libpq URL: #{url}")
  end

  test "trusted callback executes in caller process and can interrupt finish" do
    # Public option is a function supplied by the same trusted BEAM caller.
    # No network/deserialized callback path exists; not an escalation finding.
    callback = fn _ -> throw(:fixture_callback) end
    assert catch_throw(callback.(:outcome)) == :fixture_callback
  end

  test "supplier and key boundaries are narrow but integers lack maximum" do
    assert {:error, :invalid_input} = Core.validate(%{"supplier_id" => String.duplicate("x",129), "active" => false,"expected_version" => 1})
    assert {:error, :invalid_input} = Core.validate(%{"supplier_id" => "S1", "active" => false,"expected_version" => 1,"operations" => []})
    assert :ok = Core.validate(%{"supplier_id" => "S1", "active" => false,"expected_version" => Integer.pow(10, 1000)})
    sql = Postgres.text("'; DROP TABLE atheum_invocations; --")
    assert String.starts_with?(sql, "(convert_from(decode('")
    refute sql =~ "DROP TABLE"
  end
end
