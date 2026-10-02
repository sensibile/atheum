defmodule IndependentCycleTest do
  use ExUnit.Case, async: false
  alias Atheum.{Postgres, Akashic, Core}
  @moduletag :integration
  setup do
    root = Path.join(System.tmp_dir!(), "independent-" <> Postgres.id())
    File.mkdir_p!(root)
    c = %{psql: System.find_executable("psql"), pg_url: System.fetch_env!("ATHEUM_TEST_PG_URL"), binary: System.fetch_env!("AKASHIC_BINARY"), akashic_db: Path.join(root,"db"), akashic_identity: Postgres.id(), storage: :snapshot, timeout_ms: 10000}
    assert {:ok, _} = Postgres.setup(c)
    assert {:ok, %{"version" => 1}} = Akashic.apply(%{"command" => "apply", "request" => %{"request_id" => "fixture", "expected_version" => 0, "operations" => [%{"op" => "add_object", "id" => "S", "object" => %{"kind" => "supplier", "active" => true}}, %{"op" => "add_object", "id" => "B", "object" => %{"kind" => "part"}}, %{"op" => "add_object", "id" => "P", "object" => %{"kind" => "product"}}, %{"op" => "add_relation", "relation" => %{"kind" => "supplies", "from" => "S", "to" => "B"}}, %{"op" => "add_relation", "relation" => %{"kind" => "requires", "from" => "P", "to" => "B"}}]}}, c)
    on_exit(fn ->
      assert {:ok, _} = Postgres.query("BEGIN; DELETE FROM atheum_events WHERE invocation_id IN (SELECT invocation_id FROM atheum_invocations WHERE request->'target'->>'identity'=#{Postgres.text(c.akashic_identity)}); DELETE FROM atheum_invocations WHERE request->'target'->>'identity'=#{Postgres.text(c.akashic_identity)}; COMMIT;", c)
      File.rm_rf!(root)
    end)
    %{c: c, root: root, opts: [safe_retry: true, deadline_ms: System.system_time(:millisecond)+120000]}
  end
  defp accept(c,opts,key \\ Postgres.id()) do
    assert {:ok,r} = Atheum.submit(key,%{"supplier_id"=>"S","active"=>false,"expected_version"=>1},c,opts)
    r
  end
  defp blocked(c,v) do
    assert {:ok,r}=Akashic.apply(%{"command"=>"impact","version"=>v,"method"=>"full"},c)
    r["blocked_by_product"]
  end
  test "independent recovery eligibility truth table", %{c: c} do
    target=%{"db"=>Path.expand(c.akashic_db),"identity"=>c.akashic_identity,"storage"=>"snapshot"}
    for status <- ["accepted","running","unresolved","stopped","failed","succeeded"], cancel <- [false,true], safe <- [false,true], expired <- [false,true], changed <- [false,true], conflict <- [false,true] do
      request=%{"deadline_ms"=>100,"safe_retry"=>safe,"target"=>target}
      row=%{"status"=>status,"cancel_requested"=>cancel,"request"=>request,"error"=>if(conflict,do: %{"code"=>"request_conflict"},else: nil)}
      permitted=status in ["running","unresolved"] and not cancel and safe and not expired and not changed and not conflict
      actual=Core.recoverable(row,if(expired,do: 100,else: 99),if(changed,do: %{},else: target))
      assert (actual==:ok)==permitted
    end
  end
  test "response lost after real commit, recover in fresh VM", %{c: c, opts: opts, root: root} do
    wrapper=Path.join(root,"lose-response")
    File.write!(wrapper,"#!/usr/bin/env python3\nimport subprocess,sys\np=subprocess.run(["<>inspect(c.binary)<>"]+sys.argv[1:],capture_output=True)\nsys.stdout.write('truncated')\nsys.exit(p.returncode)\n")
    File.chmod!(wrapper,0o700)
    row=accept(c,opts)
    assert {:ok,lost}=Atheum.run(row["invocation_id"],%{c|binary: wrapper})
    assert {lost["status"],lost["effect_certainty"],lost["stop_confirmed"]}=={"unresolved","unknown",false}
    assert blocked(c,2)==%{"P"=>["B"]}
    ebin=Path.join([File.cwd!(),"_build","test","lib","atheum","ebin"])
    code="{:ok,r}=Atheum.recover("<>inspect(row["invocation_id"])<>","<>inspect(c)<>"); IO.puts(JSON.encode!(r))"
    {raw,0}=System.cmd(System.find_executable("elixir"),["-pa",ebin,"-e",code])
    done=JSON.decode!(String.trim(raw))
    assert done["status"]=="succeeded"
    assert done["result"]["version"]==2
    assert done["request"]==row["request"]
    assert done["execution_id"]==row["execution_id"]
    assert done["invocation_id"]!=done["execution_id"]
    assert done["attempt_id"]!=lost["attempt_id"]
    assert {:error,:not_recoverable}=Atheum.recover(row["invocation_id"],c)
  end
  test "repeated cancellation vs start race has linearizable accepted claim", %{c: c, opts: opts} do
    for _ <- 1..12 do
      r=accept(c,opts)
      parent=self()
      tasks=for operation <- [:run,:cancel], do: Task.async(fn -> receive do :go -> apply(Atheum,operation,[r["invocation_id"],c]) end end)
      Enum.each(tasks,&send(&1.pid,:go))
      results=Enum.map(tasks,&Task.await(&1,20000))
      assert {:ok,final}=Atheum.get(r["invocation_id"],c)
      assert final["cancel_requested"]
      if final["status"]=="stopped" do
        assert final["stop_confirmed"]
        assert final["effect_certainty"]=="not_started"
      else
        assert final["status"] in ["succeeded","failed"]
        refute final["stop_confirmed"]
      end
      assert Enum.any?(results, &match?({:ok,_},&1))
      assert is_pid(parent)
    end
  end
  test "blocked recovery never launches apply for cancelled or expired unknown", %{c: c, opts: opts, root: root} do
    marker=Path.join(root,"launched")
    wrapper=Path.join(root,"spy")
    File.write!(wrapper,"#!/bin/sh\ntouch "<>marker<>"\nexit 1\n")
    File.chmod!(wrapper,0o700)
    for gate <- [:cancel,:deadline] do
      r=accept(c,opts)
      assert {:ok,_}=Atheum.run(r["invocation_id"],%{c|binary: "/missing"})
      if gate==:cancel do
        assert {:ok,requested}=Atheum.cancel(r["invocation_id"],c)
        refute requested["stop_confirmed"]
      else
        assert {:ok,_}=Postgres.query("UPDATE atheum_invocations SET request=jsonb_set(request,'{deadline_ms}','0'::jsonb) WHERE invocation_id=#{Postgres.text(r["invocation_id"])}",c)
      end
      assert {:error,_}=Atheum.recover(r["invocation_id"],%{c|binary: wrapper})
      refute File.exists?(marker)
      assert {:ok,unchanged}=Atheum.get(r["invocation_id"],c)
      assert unchanged["effect_certainty"]=="unknown"
    end
  end
  test "real no-op receipt has absence of domain change and stable result", %{c: c, opts: opts} do
    assert {:ok,r}=Atheum.submit(Postgres.id(),%{"supplier_id"=>"S","active"=>true,"expected_version"=>1},c,opts)
    assert {:ok,done}=Atheum.run(r["invocation_id"],c)
    assert done["status"]=="succeeded"
    assert done["effect_certainty"]=="confirmed_absent"
    refute done["result"]["changed"]
    assert blocked(c,done["result"]["version"])==%{}
    assert {:ok,replayed}=Akashic.apply(%{"command"=>"apply","request"=>r["request"]["apply"]},c)
    assert replayed==done["result"]
  end
  test "older failure cannot replace new successful recovery", %{c: c, opts: opts} do
    r=accept(c,opts)
    owner=self()
    worker=Task.async(fn -> Atheum.run(r["invocation_id"],%{c|binary: "/missing"}, after_effect: fn error -> send(owner,{:old,error}); receive do :release -> :ok end end) end)
    assert_receive {:old,{:error,_}},10000
    assert {:ok,done}=Atheum.recover(r["invocation_id"],c)
    assert done["status"]=="succeeded"
    send(worker.pid,:release)
    assert {:error,:stale_attempt}=Task.await(worker,10000)
    assert {:ok,^done}=Atheum.get(r["invocation_id"],c)
    assert {:ok,events}=Atheum.history(r["invocation_id"],c)
    stale=Enum.find(events,&(&1["kind"]=="stale_attempt_observed"))
    assert stale["data"]["status"]=="unresolved"
    assert stale["attempt_id"]!=done["attempt_id"]
  end
end
