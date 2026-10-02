ExUnit.start(seed: 20261002, exclude: [])
defmodule IndependentDockerTest do
  use ExUnit.Case, async: false
  alias Atheum.{Akashic, Postgres}
  alias Atheum.Worker.{Docker, Manager, State}
  setup do
    root = Path.join(System.tmp_dir!(), "atheum-worker-test-" <> Postgres.id())
    File.mkdir_p!(root)

    c = %{
      psql: System.find_executable("psql"),
      docker: System.find_executable("docker"),
      pg_url: System.fetch_env!("ATHEUM_TEST_PG_URL"),
      binary: System.fetch_env!("AKASHIC_BINARY"),
      akashic_db: Path.join(root, "db"),
      akashic_identity: Postgres.id(),
      storage: :snapshot,
      timeout_ms: 10_000
    }

    assert {:ok, _} = Postgres.setup(c)

    assert {:ok, _} =
             Akashic.apply(
               %{
                 "command" => "apply",
                 "request" => %{
                   "request_id" => "seed",
                   "expected_version" => 0,
                   "operations" => [
                     %{
                       "op" => "add_object",
                       "id" => "S1",
                       "object" => %{"kind" => "supplier", "active" => true}
                     }
                   ]
                 }
               },
               c
             )

    on_exit(fn ->
      assert {:ok, :idle} = Manager.reconcile(c)
      identity = Postgres.text(c.akashic_identity)

      ids =
        "SELECT invocation_id FROM atheum_invocations WHERE request->'target'->>'identity'=#{identity}"

      assert {:ok, _} =
               Postgres.query(
                 "BEGIN; DELETE FROM atheum_worker_instances WHERE invocation_id IN (#{ids}); DELETE FROM atheum_events WHERE invocation_id IN (#{ids}); DELETE FROM atheum_invocations WHERE invocation_id IN (#{ids}); COMMIT;",
                 c
               )

      File.rm_rf!(root)
    end)

    opts = [deadline_ms: System.system_time(:millisecond) + 60_000, safe_retry: true]

    assert {:ok, row} =
             Atheum.submit(
               Postgres.id(),
               %{"supplier_id" => "S1", "active" => false, "expected_version" => 1},
               c,
               opts
             )

    %{c: c, row: row}
  end


  defp snapshot(row, c) do
    {:ok, raw} = Postgres.query("SELECT coalesce(json_agg(i),'[]') FROM atheum_worker_instances i WHERE invocation_id=" <> Postgres.text(row["invocation_id"]), c)
    IO.puts("INDEPENDENT_SNAPSHOT " <> raw)
    JSON.decode!(raw)
  end
  # Independent oracle: an unacknowledged effect remains unknown; replacing a
  # worker cannot create a new logical Apply identity. Explicit recovery advances
  # job attempt and instance while receipt version remains unchanged.
  test "independent receipt model and actual epipe", %{c: c, row: row} do
    {:ok, unknown} = Manager.run(row["invocation_id"], c,
      after_host_effect: fn i ->
        {:ok, stats} = Docker.command(["stats", "--no-stream", "--format", "{{json .}}", i["container_id"]], c)
        IO.puts("RESOURCE_SAMPLE " <> stats)
        {:ok, _} = Docker.command(["kill", i["container_id"]], c)
        Process.sleep(150)
        :ok
      end)
    IO.puts("LOST_EFFECT_STATE " <> JSON.encode!(unknown))
    assert unknown["status"] == "unresolved"
    assert unknown["effect_certainty"] == "unknown"
    refute unknown["stop_confirmed"]
    {:ok, done} = Manager.recover(row["invocation_id"], c)
    assert done["status"] == "succeeded"
    assert done["request"] == row["request"]
    assert done["generation"] == unknown["generation"] + 1
    assert done["attempt_id"] != unknown["attempt_id"]
    assert done["result"]["version"] == 2
    {:ok, replay} = Akashic.apply(%{"command" => "apply", "request" => row["request"]["apply"]}, c)
    assert replay == done["result"]
    [a,b] = Enum.sort_by(snapshot(row,c), & &1["instance_generation"])
    assert a["instance_name"] != b["instance_name"]
    assert a["container_id"] != b["container_id"]
    assert a["attempt_id"] != b["attempt_id"]
    assert a["phase"] == "removed" and b["phase"] == "removed"
  end

end
