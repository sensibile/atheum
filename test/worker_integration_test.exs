defmodule Atheum.WorkerIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration
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

  test "fixed real container returns durable result and is reclaimed", %{c: c, row: row} do
    assert {:ok, done} =
             Manager.run(row["invocation_id"], c,
               after_worker_ready: fn instance ->
                 assert {:ok, object} = Docker.inspect_owned(instance, c)
                 host = object["HostConfig"]
                 assert host["NetworkMode"] == "none"
                 assert host["ReadonlyRootfs"]
                 assert host["RestartPolicy"]["Name"] == "no"
                 assert host["Memory"] == 134_217_728
                 assert host["MemorySwap"] == 134_217_728
                 assert host["NanoCpus"] == 500_000_000
                 assert host["PidsLimit"] == 64
                 assert host["CapDrop"] == ["ALL"]
                 assert host["SecurityOpt"] == ["no-new-privileges"]
                 assert object["Config"]["User"] == "65534:65534"

                 assert Enum.all?(
                          object["Mounts"],
                          &(&1["Type"] == "tmpfs" and &1["Destination"] == "/tmp")
                        )

                 assert host["PortBindings"] in [nil, %{}]

                 IO.puts(
                   "WORKER_CONSTRAINTS " <>
                     JSON.encode!(
                       Map.take(host, [
                         "NetworkMode",
                         "ReadonlyRootfs",
                         "RestartPolicy",
                         "Memory",
                         "MemorySwap",
                         "NanoCpus",
                         "PidsLimit",
                         "CapDrop",
                         "SecurityOpt",
                         "Tmpfs",
                         "PortBindings",
                         "Binds"
                       ])
                     )
                 )

                 :ok
               end
             )

    assert done["status"] == "succeeded"
    assert done["result"]["version"] == 2
    assert {:ok, fetched} = Atheum.get(row["invocation_id"], c)
    assert fetched == done

    assert {:ok, raw} =
             Postgres.query(
               "SELECT row_to_json(i) FROM atheum_worker_instances i WHERE invocation_id=#{Postgres.text(row["invocation_id"])}",
               c
             )

    instance = JSON.decode!(raw)
    assert instance["phase"] == "removed"
    assert instance["container_id"] =~ ~r/^\w{64}$/

    assert Enum.map(instance["observations"], & &1["phase"]) == [
             "created",
             "ready",
             "executing",
             "effect_observed",
             "result_received",
             "exited",
             "removed"
           ]

    assert Docker.absent?(instance, c)
    IO.puts("WORKER_DURABLE " <> raw)
  end

  test "separate manager VM death is reclaimed by a fresh owner", %{c: c, row: row} do
    code =
      "Atheum.Worker.Manager.run(" <>
        inspect(row["invocation_id"]) <>
        ", " <>
        inspect(c) <>
        ", after_container_created: fn i -> IO.puts(JSON.encode!(i)); receive do :never -> :ok end end)"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.find_executable("elixir"))},
        [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["-pa", Path.expand("_build/test/lib/atheum/ebin"), "-e", code]
        ]
      )

    assert_receive {^port, {:data, bytes}}, 15_000
    instance = JSON.decode!(String.trim(bytes))
    assert {:error, %{"code" => "worker_lost"}} = Manager.reconcile(c)
    {:os_pid, vm} = Port.info(port, :os_pid)
    assert {"", 0} = System.cmd("/bin/kill", ["-KILL", to_string(vm)])
    assert_receive {^port, {:exit_status, _}}, 15_000
    assert {:ok, _} = Manager.reconcile(c)
    assert Docker.absent?(instance, c)
    assert {:ok, done} = Manager.recover(row["invocation_id"], c)
    assert done["result"]["version"] == 2
  end

  test "readiness timeout and worker kill preserve unknown and reclaim", %{c: c, row: row} do
    assert {:ok, unknown} = Manager.run(row["invocation_id"], Map.put(c, :worker_timeout_ms, 0))
    assert unknown["status"] == "unresolved"
    assert unknown["effect_certainty"] == "unknown"

    assert {:ok, killed} =
             Manager.recover(row["invocation_id"], c,
               after_worker_ready: fn instance ->
                 assert {:ok, _} = Docker.command(["kill", instance["container_id"]], c)
                 :ok
               end
             )

    assert killed["status"] == "unresolved"
    assert {:ok, recovered} = Manager.recover(row["invocation_id"], c)
    assert recovered["result"]["version"] == 2
    assert recovered["request"] == row["request"]
  end

  test "manager dies after effect; capacity blocks duplicates; reconcile does not retry", %{
    c: c,
    row: row
  } do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Manager.run(row["invocation_id"], c,
          after_host_effect: fn instance ->
            send(parent, {:committed, instance})

            receive do
              :never -> :ok
            end
          end
        )
      end)

    assert_receive {:committed, instance}, 15_000
    assert {:error, :capacity_busy} = Manager.recover(row["invocation_id"], c)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:error, :capacity_busy} = Manager.recover(row["invocation_id"], c)
    assert {:ok, _} = Manager.reconcile(c)
    assert Docker.absent?(instance, c)
    assert {:ok, orphan} = Atheum.get(row["invocation_id"], c)
    assert orphan["status"] == "unresolved"
    assert orphan["generation"] == 1
    assert {:ok, done} = Manager.recover(row["invocation_id"], c)
    assert done["result"]["version"] == 2
    assert done["generation"] == 2
    assert done["request"] == row["request"]

    assert {:ok, replay} =
             Akashic.apply(%{"command" => "apply", "request" => row["request"]["apply"]}, c)

    assert replay == done["result"]
    assert {:error, :not_found} = State.slot(c)
  end

  test "cancel before send blocks effect; cancel after effect preserves success", %{
    c: c,
    row: row
  } do
    assert {:ok, unknown} =
             Manager.run(row["invocation_id"], c,
               after_worker_ready: fn _ ->
                 assert {:ok, _} = Atheum.cancel(row["invocation_id"], c)
                 :ok
               end
             )

    assert unknown["status"] == "unresolved"
    assert unknown["cancel_requested"]
    assert {:error, :cancel_requested} = Manager.recover(row["invocation_id"], c)

    assert {:ok, second} =
             Atheum.submit(
               Postgres.id(),
               %{"supplier_id" => "S1", "active" => false, "expected_version" => 1},
               c,
               deadline_ms: System.system_time(:millisecond) + 60_000,
               safe_retry: true
             )

    assert {:ok, done} =
             Manager.run(second["invocation_id"], c,
               after_host_effect: fn _ ->
                 assert {:ok, _} = Atheum.cancel(second["invocation_id"], c)
                 :ok
               end
             )

    assert done["status"] == "succeeded"
    assert done["cancel_requested"]
    assert done["result"]["version"] == 2
  end

  test "lost result after committed effect replays receipt without duplicate mutation", %{
    c: c,
    row: row
  } do
    assert {:ok, unknown} =
             Manager.run(row["invocation_id"], c,
               after_host_effect: fn instance ->
                 assert {:ok, _} = Docker.command(["kill", instance["container_id"]], c)
                 :ok
               end
             )

    assert unknown["status"] == "unresolved"
    assert unknown["effect_certainty"] == "unknown"
    assert {:ok, done} = Manager.recover(row["invocation_id"], c)
    assert done["result"]["version"] == 2
    assert done["request"]["apply"] == row["request"]["apply"]
  end
end
