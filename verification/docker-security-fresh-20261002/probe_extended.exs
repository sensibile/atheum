alias Atheum.{Akashic,Postgres}
alias Atheum.Worker.{Manager,State,Spec}
out=System.fetch_env!("FRESH_OUT")
root=System.fetch_env!("FRESH_ROOT")
c=%{psql: System.find_executable("psql"),docker: Path.join(out,"docker_capture.py"),pg_url: System.fetch_env!("ATHEUM_TEST_PG_URL"),binary: System.fetch_env!("AKASHIC_BINARY"),akashic_db: Path.join(root,"db"),akashic_identity: Postgres.id(),storage: :snapshot,timeout_ms: 10000}
check=fn name,ok -> if !ok,do: raise(name); IO.puts("PASS "<>name) end
{:ok,_}=Postgres.setup(c)
{:ok,_}=Akashic.apply(%{"command"=>"apply","request"=>%{"request_id"=>"seed","expected_version"=>0,"operations"=>[%{"op"=>"add_object","id"=>"S1","object"=>%{"kind"=>"supplier","active"=>true}}]}},c)
submit=fn -> {:ok,r}=Atheum.submit(Postgres.id(),%{"supplier_id"=>"S1","active"=>false,"expected_version"=>1},c,deadline_ms: System.system_time(:millisecond)+120000,safe_retry: true); r end
r=submit.()
{:ok,cancelled}=Manager.run(r["invocation_id"],c,after_worker_ready: fn _ -> {:ok,_}=Atheum.cancel(r["invocation_id"],c); :ok end)
check.("cancel before effect unknown",cancelled["status"]=="unresolved" and cancelled["cancel_requested"])
check.("cancel recovery refused",Manager.recover(r["invocation_id"],c)=={:error,:cancel_requested})
r=submit.()
{:error,:stale_attempt}=Manager.run(r["invocation_id"],c,after_worker_result: fn _ ->
 {:ok,_}=Postgres.query("UPDATE atheum_invocations SET generation=generation+1,attempt_id='fixture-newer-attempt' WHERE invocation_id=#{Postgres.text(r["invocation_id"])}",c)
 :ok
end)
{:ok,current}=Atheum.get(r["invocation_id"],c)
{:ok,events}=Atheum.history(r["invocation_id"],c)
check.("stale actual PG completion fenced",current["generation"]==2 and current["status"]=="running" and current["result"]==nil and Enum.any?(events,&(&1["kind"]=="stale_attempt_observed")))
File.write!(Path.join(out,"stale-pg.raw"),JSON.encode!(%{"row"=>current,"history"=>events}))
# No actual container creation: image-valid CLI fixture fails create and claims absence.
{:ok,spec}=Spec.load()
f=Path.join(root,"unknown-create")
File.mkdir_p!(f)
cli=Path.join(f,"docker")
image=%{"Id"=>spec["image_id"],"Config"=>%{"Labels"=>%{"org.acropolis.atheum.source"=>spec["source_sha256"],"org.acropolis.atheum.worker_spec"=>spec["spec"]}}}
File.write!(Path.join(f,"image.json"),JSON.encode!(image))
File.write!(cli,"#!/usr/bin/env python3\nimport sys,json\nfrom pathlib import Path\nr=Path(__file__).parent\nwith (r/'argv.raw').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nif sys.argv[1]=='image': print((r/'image.json').read_text())\nelif sys.argv[1]=='create': sys.exit(1)\nelif sys.argv[1]=='inspect': print((r/'object.json').read_text() if (r/'object.json').exists() else '{}')\nelif sys.argv[1]=='rm': print('fixture-removed')\n")
File.chmod!(cli,0o755)
fc=%{c | docker: cli}
r=submit.()
{:ok,unknown}=Manager.run(r["invocation_id"],fc)
check.("unknown create remains unknown",unknown["status"]=="unresolved" and unknown["effect_certainty"]=="unknown")
{:ok,slot}=State.slot(fc)
{:ok,instance}=State.for_owner(slot["owner_token"],fc)
check.("unknown create slot retained",instance["container_id"]==nil and instance["phase"]=="create_intent")
check.("unknown create reconcile refuses absence",match?({:error,_},Manager.reconcile(fc)))
# Fake owned removal proves only fixture state; no Docker daemon mutation occurs.
object=%{"Image"=>instance["image_id"],"Id"=>String.duplicate("c",64),"Config"=>%{"Labels"=>%{"org.acropolis.atheum.owner"=>instance["owner_token"],"org.acropolis.atheum.worker"=>"supplier-set-active-v1","org.acropolis.atheum.instance_generation"=>to_string(instance["instance_generation"])}}}
File.write!(Path.join(f,"object.json"),JSON.encode!(object))
{:ok,_}=Manager.reconcile(fc)
check.("fixture reservation reclaimed",State.slot(fc)=={:error,:not_found})
File.cp!(Path.join(f,"argv.raw"),Path.join(out,"unknown-create-argv.raw"))
check.("real manager idle",Manager.reconcile(c)=={:ok,:idle})
IO.puts("ALL EXTENDED PROBES COMPLETED")
