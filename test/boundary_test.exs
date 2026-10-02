defmodule Atheum.BoundaryTest do
  use ExUnit.Case, async: true
  alias Atheum.{Akashic, Core, Postgres, ProcessIO, Wire}
  @url "postgres://postgres@127.0.0.1:55440/atheum_cycle_test"

  setup do
    root = Path.join(System.tmp_dir!(), "atheum-boundary-" <> Postgres.id())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp executable(root, body) do
    path = Path.join(root, Postgres.id())
    File.write!(path, "#!/usr/bin/env python3\n" <> body)
    File.chmod!(path, 0o700)
    path
  end

  test "libpq override and ambiguous URL components are rejected before any process", %{
    root: root
  } do
    marker = Path.join(root, "unexpected-process")
    bin = executable(root, "from pathlib import Path\nPath(" <> inspect(marker) <> ").touch()\n")

    for suffix <- [
          "?dbname=atheum_cycle_test",
          "?hostaddr=127.0.0.1",
          "?service=anything",
          "#fragment"
        ] do
      assert {:error, %{"code" => "invalid_configuration"}} =
               Postgres.query("SELECT 1", %{psql: bin, pg_url: @url <> suffix})
    end

    refute File.exists?(marker)
    assert {:ok, %{database: "atheum_cycle_test", port: 55_440}} = Postgres.connection(@url)

    for url <- [
          "postgres://postgres@localhost/atheum_cycle_test",
          "postgres://postgres:password@localhost:55440/atheum_cycle_test",
          "postgres://postgres@127.0.0.1:55440/atheum_%63ycle_test"
        ] do
      assert {:error, _error} = Postgres.connection(url)
    end
  end

  test "PG uses validated separate argv and overrides inherited target options", %{root: root} do
    bin =
      executable(
        root,
        "import json,os,sys\nprint(json.dumps({'args':sys.argv[1:],'hostaddr':os.environ.get('PGHOSTADDR'),'options':os.environ.get('PGOPTIONS')}))\n"
      )

    assert {:ok, output} =
             Postgres.query("SELECT 1", %{psql: bin, pg_url: @url, pg_timeout_ms: 1000})

    result = JSON.decode!(output)
    assert Enum.chunk_every(result["args"], 2) != []

    assert Enum.at(result["args"], Enum.find_index(result["args"], &(&1 == "-d")) + 1) ==
             "atheum_cycle_test"

    assert result["hostaddr"] == nil
    assert result["options"] == "-c statement_timeout=1000 -c lock_timeout=1000"
    refute @url in result["args"]
  end

  test "psql observation is bounded and does not return fabricated success", %{root: root} do
    bin = executable(root, "import sys\nsys.stdin.buffer.read()\nprint('{}')\n")
    start = System.monotonic_time(:millisecond)

    assert {:error, %{"code" => "journal_timeout"}} =
             Postgres.query("SELECT 1", %{psql: bin, pg_url: @url, pg_timeout_ms: 50})

    assert System.monotonic_time(:millisecond) - start < 1000
  end

  test "CLI output and JSON nesting have finite limits", %{root: root} do
    bin = executable(root, "import sys\nsys.stdout.write('x'*(4*1024*1024))\n")
    assert {:error, %{"code" => "output_limit"}} = ProcessIO.run(bin, [], 2000)

    assert {:error, _error} =
             Wire.decode(String.duplicate("[", 33) <> "0" <> String.duplicate("]", 33))

    assert {:ok, _value} = Wire.decode(JSON.encode!(%{"quoted" => "[{\\\"not nesting}]}"}))
  end

  test "empty, wrong-type and unrelated CLI successes stay unknown", %{root: root} do
    request = %{"command" => "apply", "request" => %{"expected_version" => 1}}

    for result <- [%{}, %{"changed" => "false"}, [], valid_result(3, true)] do
      wire = %{"ok" => true, "result" => %{"apply" => result}}
      bin = executable(root, "print(" <> inspect(JSON.encode!(wire)) <> ")\n")

      assert {:error, error} =
               Akashic.apply(request, %{
                 binary: bin,
                 storage: :snapshot,
                 akashic_db: root,
                 timeout_ms: 1000
               })

      assert {"unresolved", "unknown", nil, _error} = Core.completion({:error, error})
    end

    for result <- [%{}, %{"changed" => "false"}, [], "wrong"] do
      assert {"unresolved", "unknown", nil, _error} = Core.completion({:ok, result})
    end

    assert {:error, _error} =
             Wire.response(%{"ok" => false, "error" => %{"code" => "invalid_input"}}, 2, request)

    assert {:ok, _result} =
             Wire.response(
               %{"ok" => true, "result" => %{"apply" => valid_result(2, true)}},
               0,
               request
             )

    assert {:ok, _result} =
             Wire.response(
               %{"ok" => true, "result" => %{"apply" => valid_result(1, false)}},
               0,
               request
             )
  end

  test "oversized version and invalid observation timeout are refused", %{root: root} do
    assert {:error, :invalid_input} =
             Core.validate(%{
               "supplier_id" => "S1",
               "active" => false,
               "expected_version" => Integer.pow(10, 1000)
             })

    assert {:error, %{"code" => "invalid_configuration"}} = ProcessIO.run(root, [], 0)
    assert {:error, %{"code" => "invalid_configuration"}} = ProcessIO.run(root, [], 60_001)
  end

  defp valid_result(version, changed) do
    %{
      "version" => version,
      "changed" => changed,
      "difference" => %{
        "added_products" => [],
        "newly_blocked" => [],
        "removed_products" => [],
        "restored" => []
      },
      "work" => %{"recomputed_parts" => 0, "recomputed_products" => 0, "visited_relations" => 0}
    }
  end
end
