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

  test "concurrent capacity and reservation recovery before create", %{c: c,row: row} do
    parent=self()
    contenders=for _ <- 1..16 do
      spawn(fn -> send(parent,{:reserved,State.reserve(row["invocation_id"],c)}) end)
    end
    results=for _ <- contenders do receive do {:reserved,r}->r after 15000 -> flunk("reservation timeout") end end
    assert Enum.count(results,&match?({:ok,_},&1))==1
    assert Enum.count(results,&(&1=={:error,:capacity_busy}))==15
    assert {:ok,_}=Manager.reconcile(c)
    assert {:error,:not_found}=State.slot(c)
    {:ok, still}=Atheum.get(row["invocation_id"],c)
    assert still["status"]=="accepted"
    assert still["generation"]==0
  end

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

  test "cancellation after lost effect prohibits receipt reapply", %{c: c,row: row} do
    {:ok, unknown}=Manager.run(row["invocation_id"],c,after_host_effect: fn i ->
      {:ok,_}=Atheum.cancel(row["invocation_id"],c)
      {:ok,_}=Docker.command(["kill",i["container_id"]],c)
      Process.sleep(150)
      :ok
    end)
    assert unknown["status"]=="unresolved"
    assert unknown["effect_certainty"]=="unknown"
    assert unknown["cancel_requested"]
    refute unknown["stop_confirmed"]
    assert {:error,:cancel_requested}=Manager.recover(row["invocation_id"],c)
    [i]=snapshot(row,c)
    assert i["phase"]=="removed"
  end
  test "manager killed during actual create response gap", %{c: c,row: row} do
    wrapper=Path.join(Path.dirname(c.akashic_db),"docker-create-gap")
    marker=wrapper<>".marker"
    File.write!(wrapper, "#!/usr/bin/env python3\nimport subprocess,sys,time,pathlib,os\na=sys.argv[1:]\nif a[0]=='create':\n p=subprocess.run(['/usr/local/bin/docker']+a,capture_output=True)\n pathlib.Path("<>inspect(marker)<>").write_text(p.stdout.decode())\n time.sleep(45)\n sys.stdout.buffer.write(p.stdout)\n sys.stderr.buffer.write(p.stderr)\n sys.exit(p.returncode)\nelse: os.execv('/usr/local/bin/docker',['docker']+a)\n")
    File.chmod!(wrapper,0o700)
    code="IO.inspect(Atheum.Worker.Manager.run("<>inspect(row["invocation_id"])<>", "<>inspect(Map.put(c,:docker,wrapper))<>"))"
    port=Port.open({:spawn_executable,String.to_charlist(System.find_executable("elixir"))},[:binary,:exit_status,:use_stdio,args: ["-pa",Path.expand("_build/test/lib/atheum/ebin"),"-e",code]])
    {:os_pid,vm}=Port.info(port,:os_pid)
    try do
      Enum.reduce_while(1..150,:waiting,fn _,_ ->
        if File.exists?(marker),do: {:halt,:ready},else: (Process.sleep(100); {:cont,:waiting})
      end)
      assert File.exists?(marker)
      {:ok,slot}=State.slot(c)
      {:ok,i}=State.for_owner(slot["owner_token"],c)
      assert i["phase"]=="create_intent"
      assert is_nil(i["container_id"])
      assert byte_size(String.trim(File.read!(marker)))==64
      assert {:error,:capacity_busy}=Manager.run(row["invocation_id"],c)
      assert {"",0}=System.cmd("/bin/kill",["-KILL",to_string(vm)])
      assert_receive {^port,{:exit_status,_}},15000
      assert {:ok,_}=Manager.reconcile(c)
      assert Docker.absent?(i,c)
      {:ok,current}=Atheum.get(row["invocation_id"],c)
      assert current["status"]=="unresolved"
      assert current["effect_certainty"]=="unknown"
      assert current["generation"]==1
      assert {:error,:not_found}=State.slot(c)
      snapshot(row,c)
    after
      System.cmd("/bin/kill",["-KILL",to_string(vm)])
    end
  end

end
