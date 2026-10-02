defmodule Atheum.FinalIndependentTest do
  use ExUnit.Case, async: false
  alias Atheum.{Postgres, Akashic, Wire, Core, ProcessIO}
  @url "postgres://postgres@127.0.0.1:55440/atheum_cycle_test"

  setup do
    root = Path.join(System.tmp_dir!(), "atheum-final-" <> Postgres.id())
    File.mkdir_p!(root)
    c = %{psql: System.find_executable("psql"), pg_url: @url,
      binary: System.fetch_env!("AKASHIC_BINARY"), akashic_db: Path.join(root,"db"),
      akashic_identity: Postgres.id(), storage: :snapshot, timeout_ms: 5000}
    on_exit(fn ->
      {:ok, _} = Postgres.query("BEGIN; DELETE FROM atheum_events WHERE invocation_id IN (SELECT invocation_id FROM atheum_invocations WHERE request->'target'->>'identity'=#{Postgres.text(c.akashic_identity)}); DELETE FROM atheum_invocations WHERE request->'target'->>'identity'=#{Postgres.text(c.akashic_identity)}; COMMIT;", c)
      File.rm_rf!(root)
    end)
    assert {:ok, _} = Postgres.setup(c)
    assert {:ok, %{"version" => 1}} = Akashic.apply(%{"command" => "apply", "request" => %{"request_id" => "fixture", "expected_version" => 0, "operations" => [%{"op" => "add_object", "id" => "S", "object" => %{"kind" => "supplier", "active" => true}}]}},c)
    %{c: c, root: root, opts: [deadline_ms: System.system_time(:millisecond)+60000, safe_retry: true]}
  end

  defp accept(c, opts, key) do
    Atheum.submit(key, %{"supplier_id" => "S", "active" => false,"expected_version" => 1}, c, opts)
  end
  defp script(root, body) do
    p=Path.join(root,Postgres.id())
    File.write!(p,"#!/usr/bin/env python3\n"<>body)
    File.chmod!(p,0o700)
    p
  end
  defp version(c) do
    {raw,0}=System.cmd(c.binary,["--db",c.akashic_db,"--json",JSON.encode!(%{"command"=>"validate"})])
    JSON.decode!(raw)["result"]["version"]
  end
  defp result do
    %{"changed"=>true,"version"=>2,"difference"=>%{"added_products"=>[],"removed_products"=>[],"newly_blocked"=>[],"restored"=>[]},"work"=>%{"recomputed_parts"=>0,"recomputed_products"=>0,"visited_relations"=>0}}
  end

  test "independent URL rejection matrix never launches adapter", %{c: c, root: root} do
    marker=Path.join(root,"launched")
    p=script(root,"from pathlib import Path\nPath("<>inspect(marker)<>").touch()\n")
    urls=[@url<>"?dbname=postgres",@url<>"?dbname=atheum_cycle_test&dbname=postgres",@url<>"?%64bname=postgres",@url<>"?host=remote",@url<>"?service=x",@url<>"#dbname=postgres",
      "postgres://postgres@127.0.0.1:55440/atheum_%63ycle_test",
      "postgres://postgres@127.0.0.1:55440/atheum_cycle_test%3Fdbname%3Dpostgres",
      "postgres://postgres@127.0.0.1:55440/atheum_cycle_test/../postgres",
      "postgres://postgres@127.0.0.1:55440//atheum_cycle_test",
      "postgres://postgres:pw@127.0.0.1:55440/atheum_cycle_test",
      "postgres://postgres%40x@127.0.0.1:55440/atheum_cycle_test",
      "postgres://postgres@127.0.0.1/atheum_cycle_test",
      "dbname=atheum_cycle_test dbname=postgres"]
    for url <- urls do
      assert {:error,%{"code"=>"invalid_configuration"}}=Postgres.query("SELECT 1",%{c|psql: p,pg_url: url})
    end
    refute File.exists?(marker)
    assert {:ok,"atheum_cycle_test"}=Postgres.query("SELECT current_database()",c)
    IO.puts("URL_MATRIX #{JSON.encode!(urls)}")
  end

  test "independent concurrent acceptance stable identities and one event", %{c: c, opts: opts} do
    key=Postgres.id()
    rows=1..8 |> Enum.map(fn _ -> Task.async(fn -> accept(c,opts,key) end) end) |> Enum.map(fn t -> {:ok,r}=Task.await(t,15000);r end)
    assert length(Enum.uniq(Enum.map(rows,& &1["invocation_id"])))==1
    assert length(Enum.uniq(Enum.map(rows,& &1["execution_id"])))==1
    assert length(Enum.uniq(Enum.map(rows,& &1["request"]["apply"])))==1
    {:ok,events}=Atheum.history(hd(rows)["invocation_id"],c)
    assert Enum.map(events,& &1["kind"])==["accepted"]
    assert {:error,:acceptance_conflict}=accept(c,Keyword.put(opts,:safe_retry,false),key)
    IO.puts("IDENTITY #{JSON.encode!(hd(rows))}")
  end

  test "independent live worker recovery and stale result fencing", %{c: c,opts: opts} do
    {:ok,row}=accept(c,opts,Postgres.id()); parent=self()
    worker=Task.async(fn -> Atheum.run(row["invocation_id"],c,after_effect: fn outcome -> send(parent,{:ready,outcome}); receive do :release -> :ok end end) end)
    assert_receive {:ready,{:ok,first}},10000
    {:ok,pending}=Atheum.get(row["invocation_id"],c)
    assert pending["effect_certainty"]=="unknown"
    {:ok,new}=Atheum.recover(row["invocation_id"],c)
    send(worker.pid,:release)
    assert {:error,:stale_attempt}=Task.await(worker,10000)
    assert {:ok,^new}=Atheum.get(row["invocation_id"],c)
    assert new["result"]==first
    assert new["request"]["apply"]==row["request"]["apply"]
    assert version(c)==2
    {:ok,events}=Atheum.history(row["invocation_id"],c)
    assert List.last(events)["kind"]=="stale_attempt_observed"
    IO.puts("STALE_HISTORY #{JSON.encode!(events)}")
  end

  test "independent cancellation wins before run and recovery stays unknown", %{c: c, opts: opts,root: root} do
    {:ok,row}=accept(c,opts,Postgres.id())
    {:ok,stopped}=Atheum.cancel(row["invocation_id"],c)
    assert stopped["stop_confirmed"]
    assert {:error,:not_accepted}=Atheum.run(row["invocation_id"],c)
    assert version(c)==1
    {:ok,row2}=accept(c,opts,Postgres.id())
    p=script(root,"import subprocess,sys\nr=subprocess.run(["<>inspect(c.binary)<>"]+sys.argv[1:],capture_output=True)\nsys.stdin.buffer.read()\n")
    {:ok,unknown}=Atheum.run(row2["invocation_id"],%{c|binary: p,timeout_ms: 500})
    assert unknown["status"]=="unresolved"
    assert unknown["effect_certainty"]=="unknown"
    refute unknown["stop_confirmed"]
    assert version(c)==2
    {:ok,_}=Atheum.cancel(row2["invocation_id"],c)
    assert {:error,:cancel_requested}=Atheum.recover(row2["invocation_id"],c)
    {:ok,still}=Atheum.get(row2["invocation_id"],c)
    assert still["effect_certainty"]=="unknown"
    refute still["stop_confirmed"]
    IO.puts("CANCEL_UNKNOWN #{JSON.encode!(still)}")
  end

  test "independent PG and CLI output limits; timeout bounds", %{c: c,root: root} do
    p=script(root,"import sys\nsys.stdout.write('x'*2097152)\n")
    assert {:error,%{"code"=>"output_limit"}}=ProcessIO.run(p,[],1000)
    assert {:error,%{"code"=>"journal_output_limit"}}=Postgres.query("SELECT 1",%{c|psql: p})
    start=System.monotonic_time(:millisecond)
    assert {:error,e}=Postgres.query("SELECT pg_sleep(1)",Map.put(c,:pg_timeout_ms,50))
    assert e["code"] in ["journal_failure","journal_timeout"]
    assert System.monotonic_time(:millisecond)-start<1000
    assert {:error,%{"code"=>"journal_output_limit"}}=Postgres.query("SELECT repeat('x',1100000)",c)
  end

  test "independent malformed success matrix always remains unknown" do
    req=%{"command"=>"apply","request"=>%{"expected_version"=>1}}
    for bad <- [%{},nil,[],Map.put(result(),"changed",1),Map.put(result(),"version",3),Map.put(result(),"work",%{}),Map.put(result(),"difference",%{}),Map.put(result(),"version",-1)] do
      assert {:error,error}=Wire.response(%{"ok"=>true,"result"=>%{"apply"=>bad}},0,req)
      assert {"unresolved","unknown",nil,_}=Core.completion({:error,error})
    end
    assert {:error,_}=Wire.response(%{"ok"=>true,"result"=>%{"apply"=>result()}},1,req)
  end

  test "contradictory success and rejection after real effect must remain unknown", %{c: c,root: root,opts: opts} do
    wire_path=Path.join(root,"contradictory-wire.json")
    p=script(root,"import subprocess,sys,json\nr=subprocess.run(["<>inspect(c.binary)<>"]+sys.argv[1:],capture_output=True,check=True)\nw=json.loads(r.stdout)\nw['ok']=False\nw['error']={'code':'invalid_input','detail':'contradictory injected envelope'}\nopen("<>inspect(wire_path)<>", 'w').write(json.dumps(w))\nprint(json.dumps(w))\nsys.exit(2)\n")
    {:ok,row}=accept(c,opts,Postgres.id())
    {:ok,done}=Atheum.run(row["invocation_id"],%{c|binary: p})
    IO.puts("CONTRADICTORY_ACTUAL #{JSON.encode!(done)} ACTUAL_VERSION=#{version(c)}")
    IO.puts("CONTRADICTORY_WIRE #{File.read!(wire_path)} RECOVERY=#{inspect(Atheum.recover(row["invocation_id"],c))}")
    assert version(c)==2
    assert done["status"]=="unresolved"
    assert done["effect_certainty"]=="unknown"
  end
  test "independent worker death and result journal failure preserve unknown", %{c: c, opts: opts} do
    {:ok,row}=accept(c,opts,Postgres.id()); parent=self()
    {pid,ref}=spawn_monitor(fn -> Atheum.run(row["invocation_id"],c,after_effect: fn outcome -> send(parent,{:effect,outcome}); receive do :never -> :ok end end) end)
    assert_receive {:effect,{:ok,first}},10000
    Process.exit(pid,:kill)
    assert_receive {:DOWN,^ref,:process,^pid,:killed}
    {:ok,pending}=Atheum.get(row["invocation_id"],c)
    assert pending["status"]=="running"
    assert pending["effect_certainty"]=="unknown"
    assert {:ok,new}=Atheum.recover(row["invocation_id"],c)
    assert new["result"]==first
    assert new["request"]["apply"]==row["request"]["apply"]
    # A second logical no-op still has its own receipt and can lose its PG completion.
    {:ok,r2}=Atheum.submit(Postgres.id(),%{"supplier_id"=>"S","active"=>false,"expected_version"=>2},c,opts)
    name="final_fail_"<>Postgres.id()
    sql="CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.invocation_id=#{Postgres.text(r2["invocation_id"])} AND NEW.kind='attempt_observed' THEN RAISE EXCEPTION 'independent completion failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER #{name} BEFORE INSERT ON atheum_events FOR EACH ROW EXECUTE FUNCTION #{name}();"
    assert {:ok,_}=Postgres.query(sql,c)
    try do
      assert {:error,%{"code"=>"journal_failure"}}=Atheum.run(r2["invocation_id"],c)
      {:ok,p}=Atheum.get(r2["invocation_id"],c)
      assert p["status"]=="running"
      assert p["effect_certainty"]=="unknown"
      assert version(c)==2
      IO.puts("WRITE_FAILURE_UNKNOWN #{JSON.encode!(p)}")
    after
      assert {:ok,_}=Postgres.query("DROP TRIGGER #{name} ON atheum_events; DROP FUNCTION #{name}();",c)
    end
    {:ok,r}=Atheum.recover(r2["invocation_id"],c)
    assert r["result"]["changed"]==false
    assert r["effect_certainty"]=="confirmed_absent"
  end

  test "independent expired recovery cannot retrieve receipt by replay", %{c: c,opts: opts} do
    {:ok,row}=accept(c,opts,Postgres.id())
    assert {:ok,_}=Atheum.run(row["invocation_id"],%{c|binary: "/missing"})
    # Modify only this fixture invocation to avoid time-based scheduling assertions.
    assert {:ok,_}=Postgres.query("UPDATE atheum_invocations SET request=jsonb_set(request,'{deadline_ms}','0') WHERE invocation_id=#{Postgres.text(row["invocation_id"])}",c)
    assert {:error,:deadline_expired}=Atheum.recover(row["invocation_id"],c)
    {:ok,unknown}=Atheum.get(row["invocation_id"],c)
    assert unknown["effect_certainty"]=="unknown"
    assert version(c)==1
  end

  test "independent start cancel races retain consistent evidence", %{c: c,opts: opts} do
    for _ <- 1..12 do
      before_version=version(c)
      {:ok,row}=Atheum.submit(Postgres.id(),%{"supplier_id"=>"S","active"=>false,"expected_version"=>before_version},c,opts)
      id=row["invocation_id"]
      a=Task.async(fn -> receive do :go -> Atheum.run(id,c) end end)
      b=Task.async(fn -> receive do :go -> Atheum.cancel(id,c) end end)
      send(a.pid,:go);send(b.pid,:go)
      run_out=Task.await(a,10000);cancel_out=Task.await(b,10000)
      assert match?({:ok,_},cancel_out)
      {:ok,final}=Atheum.get(id,c)
      {:ok,h}=Atheum.history(id,c)
      assert final["cancel_requested"]
      assert final["status"] in ["stopped","succeeded"]
      if final["status"]=="stopped" do
        assert final["stop_confirmed"]
        assert final["effect_certainty"]=="not_started"
        assert version(c)==before_version
      else
        refute final["stop_confirmed"]
      end
      IO.puts("CANCEL_RACE #{inspect(run_out)} #{JSON.encode!(final)} EVENTS=#{JSON.encode!(Enum.map(h,& &1["kind"]))}")
    end
  end

end
