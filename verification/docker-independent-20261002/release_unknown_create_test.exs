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
  test "unknown create absent cannot release reservation", %{c: c,row: row} do
    {:ok,token}=State.reserve(row["invocation_id"],c)
    {:ok,spec}=Atheum.Worker.Spec.load()
    claimed=Map.merge(row,%{"attempt_id"=>"create-gap", "generation"=>1})
    {:ok,i}=State.plan(claimed,token,spec,c)
    assert {:error,_}=Manager.reconcile(c)
    assert {:ok,%{"owner_token"=>^token}}=State.slot(c)
    assert {:error,:capacity_busy}=Manager.run(row["invocation_id"],c)
    # Simulate late Docker create completing after its original caller died.
    {:ok,id}=Docker.create(i,c)
    assert byte_size(id)==64
    assert {:ok,_}=Manager.reconcile(c)
    assert Docker.absent?(i,c)
    assert {:error,:not_found}=State.slot(c)
    snapshot(row,c)
  end

end
