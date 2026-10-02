alias Atheum.{Akashic, Postgres, Wire}
alias Atheum.Worker.{Docker, Manager, Protocol, Spec, State}
out = System.fetch_env!("FRESH_OUT")
root = System.fetch_env!("FRESH_ROOT")
c = %{psql: System.find_executable("psql"), docker: Path.join(out,"docker_capture.py"), pg_url: System.fetch_env!("ATHEUM_TEST_PG_URL"), binary: System.fetch_env!("AKASHIC_BINARY"), akashic_db: Path.join(root,"akashic"), akashic_identity: Postgres.id(), storage: :snapshot, timeout_ms: 10000}
check = fn name, value -> if !value, do: raise(name); IO.puts("PASS " <> name) end
{:ok,spec} = Spec.load()
:ok = Docker.verify(spec,c)
{:ok,_} = Postgres.setup(c)
{:ok,_} = Akashic.apply(%{"command"=>"apply","request"=>%{"request_id"=>"seed","expected_version"=>0,"operations"=>[%{"op"=>"add_object","id"=>"S1","object"=>%{"kind"=>"supplier","active"=>true}}]}},c)
submit = fn supplier, version ->
 {:ok,row}=Atheum.submit(Postgres.id(),%{"supplier_id"=>supplier,"active"=>false,"expected_version"=>version},c,deadline_ms: System.system_time(:millisecond)+120000,safe_retry: true)
 row
end
row=submit.("S1",1)
{:ok,done}=Manager.run(row["invocation_id"],c,after_worker_ready: fn i ->
 {:ok,o}=Docker.inspect_owned(i,c)
 File.write!(Path.join(out,"container-inspect.raw"),JSON.encode!(o))
 h=o["HostConfig"]
 check.("actual isolation", h["NetworkMode"]=="none" and h["ReadonlyRootfs"] and h["Privileged"]==false and h["CapDrop"]==["ALL"] and h["SecurityOpt"]==["no-new-privileges"] and h["Memory"]==134217728 and h["MemorySwap"]==134217728 and h["NanoCpus"]==500000000 and h["PidsLimit"]==64 and h["Binds"] in [nil,[]] and h["PortBindings"] in [nil,%{}] and o["Config"]["User"]=="65534:65534" and Enum.all?(o["Mounts"], &(&1["Type"]=="tmpfs" and &1["Destination"]=="/tmp")))
 check.("no host secret sentinel in image env", !Enum.any?(o["Config"]["Env"], &String.contains?(&1,"ATHEUM_SECRET_SENTINEL")))
 check.("capacity 1",Manager.run(row["invocation_id"],c)=={:error,:capacity_busy})
 :ok
end)
check.("durable success",done["status"]=="succeeded" and done["result"]["version"]==2)
{:ok,history}=Atheum.history(row["invocation_id"],c)
File.write!(Path.join(out,"history.raw"),JSON.encode!(history))
{:ok,rows}=Postgres.query("SELECT coalesce(json_agg(i),'[]'::json) FROM atheum_worker_instances i",c)
File.write!(Path.join(out,"instances-first.raw"),rows)
check.("reclaimed success", State.slot(c)=={:error,:not_found})
# Real post-effect manager death: retain slot, reconcile without retry, then same receipt.
second=submit.("S1",2)
parent=self()
{pid,ref}=spawn_monitor(fn -> Manager.run(second["invocation_id"],c,after_host_effect: fn i -> send(parent,{:effect,i}); receive do :never -> :ok end end) end)
i=receive do {:effect,i}->i after 15000 -> raise "effect timeout" end
check.("busy after effect",Manager.recover(second["invocation_id"],c)=={:error,:capacity_busy})
Process.exit(pid,:kill)
receive do {:DOWN,^ref,:process,^pid,:killed}->:ok after 1000 -> raise "death timeout" end
{:ok,_}=Manager.reconcile(c)
check.("orphan absent",Docker.absent?(i,c))
{:ok,orphan}=Atheum.get(second["invocation_id"],c)
check.("reconcile no retry",orphan["status"]=="unresolved" and orphan["generation"]==1 and orphan["effect_certainty"]=="unknown")
{:ok,recovered}=Manager.recover(second["invocation_id"],c)
check.("same receipt recovery", recovered["status"]=="succeeded" and recovered["generation"]==2 and recovered["request"]==second["request"] and recovered["result"]["version"]==2)
{:ok,replayed}=Akashic.apply(%{"command"=>"apply","request"=>second["request"]["apply"]},c)
check.("no duplicate mutation",replayed==recovered["result"])
# Supplier input contains shell/option/path text but remains JSON data.
injection="--privileged;$(touch /tmp/atheum-security-never);../../secret"
third=submit.(injection,2)
{:ok,rejected}=Manager.run(third["invocation_id"],c)
check.("untrusted supplier stays data",rejected["status"] != "succeeded" and !File.exists?("/tmp/atheum-security-never"))
# Lost output after effect preserves unknown, later safe recovery.
fourth=submit.("S1",2)
{:ok,lost}=Manager.run(fourth["invocation_id"],c,after_host_effect: fn i -> {:ok,_}=Docker.command(["kill",i["container_id"]],c); :ok end)
check.("lost result unknown",lost["status"]=="unresolved" and lost["effect_certainty"]=="unknown")
{:ok,again}=Manager.recover(fourth["invocation_id"],c)
check.("lost result replay",again["status"]=="succeeded" and again["request"]==fourth["request"])
# Record final PG state before removing our entire dedicated DB externally.
for {name,table} <- [{"invocations","atheum_invocations"},{"instances","atheum_worker_instances"},{"events","atheum_events"},{"slots","atheum_worker_slots"}] do
 {:ok,bytes}=Postgres.query("SELECT coalesce(json_agg(t),'[]'::json) FROM #{table} t",c)
 File.write!(Path.join(out,name<>".raw"),bytes)
end
check.("final idle",Manager.reconcile(c)=={:ok,:idle})
# Safe fake Docker: reject image label mismatch, wrong owner/ID/generation before rm.
f=Path.join(root,"fixture")
File.mkdir_p!(f)
System.put_env("FRESH_FIXTURE",f)
fc=%{c | docker: Path.join(out,"docker_fixture.py")}
instance=%{"instance_name"=>"atheum-worker-fixture","owner_token"=>"owner","instance_generation"=>1,"image_id"=>spec["image_id"],"container_id"=>String.duplicate("a",64)}
obj=%{"Image"=>spec["image_id"],"Id"=>instance["container_id"],"Config"=>%{"Labels"=>%{"org.acropolis.atheum.owner"=>"owner","org.acropolis.atheum.worker"=>"supplier-set-active-v1","org.acropolis.atheum.instance_generation"=>"1"}}}
for {name,bad} <- [{"foreign owner",put_in(obj,["Config","Labels","org.acropolis.atheum.owner"],"foreign")},{"wrong generation",put_in(obj,["Config","Labels","org.acropolis.atheum.instance_generation"],"2")},{"wrong ID",Map.put(obj,"Id",String.duplicate("b",64))},{"wrong image",Map.put(obj,"Image","sha256:"<>String.duplicate("b",64))}] do
 File.write!(Path.join(f,"response.json"),JSON.encode!(bad))
 check.(name,match?({:error,_},Docker.remove(instance,fc)))
end
File.write!(Path.join(f,"response.json"),JSON.encode!(%{"Id"=>spec["image_id"],"Config"=>%{"Labels"=>%{}}}))
check.("image mismatched label",match?({:error,_},Docker.verify(spec,fc)))
File.cp!(Path.join(f,"argv.raw"),Path.join(out,"fixture-argv.raw"))
check.("foreign fixture never removed",!String.contains?(File.read!(Path.join(f,"argv.raw")),"\"rm\""))
# Exact response matching and parser ambiguity checks.
check.("duplicate key rejected",match?({:error,_},Wire.decode("{\"ok\":true,\"ok\":false}")))
job=Protocol.job(row,"fixture")
check.("arbitrary operation rejected",match?({:error,_},Protocol.plan(put_in(job,["request","operations"],[%{"op"=>"delete_object","id"=>"S1"}]))))
obs=Protocol.observation("stale",{:ok,done["result"]})
check.("stale attempt rejected",match?({:error,_},Protocol.result(job,obs)))
IO.puts("ALL PROBES COMPLETED")
