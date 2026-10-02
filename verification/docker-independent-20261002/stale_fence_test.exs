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
  test "late worker result cannot overwrite newer durable attempt", %{c: c, row: row} do
    parent=self()
    {pid,ref}=spawn_monitor(fn ->
      result=Manager.run(row["invocation_id"], c,
        after_worker_result: fn i ->
          send(parent,{:waiting,i})
          receive do :resume -> :ok end
        end)
      send(parent,{:old_result,result})
    end)
    assert_receive {:waiting,i}, 15000
    assert {:error,:capacity_busy}=Manager.run(row["invocation_id"],c)
    {:ok, before}=Atheum.get(row["invocation_id"],c)
    # A controlled newer durable attempt is injected in our private DB only.
    {:ok, newer}=Postgres.transition(row["invocation_id"], "generation=1",
      "generation=2,attempt_id='independent-newer',status='unresolved',effect_certainty='unknown'",
      "independent_supersede", %{},c)
    send(pid,:resume)
    assert_receive {:old_result,{:error,:stale_attempt}},15000
    assert_receive {:DOWN,^ref,:process,^pid,:normal},15000
    {:ok, after_row}=Atheum.get(row["invocation_id"],c)
    assert after_row == newer
    assert before["attempt_id"] == i["attempt_id"]
    {:ok, events}=Atheum.history(row["invocation_id"],c)
    assert Enum.any?(events,&(&1["kind"]=="stale_attempt_observed"))
    assert {:error,:not_found}=State.slot(c)
  end

end
