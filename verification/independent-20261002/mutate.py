import subprocess,os,json,pathlib,tempfile,shutil,sys
v=pathlib.Path(__file__).resolve().parent; w=pathlib.Path((v/'workspace.txt').read_text().strip()); env=os.environ.copy(); env.update(ATHEUM_TEST_PG_URL='postgres://postgres@127.0.0.1:55440/atheum_cycle_test',AKASHIC_BINARY='/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic')
mutations=[
('stale_fence','lib/atheum.ex','"generation=#{row["generation"]} AND attempt_id=#{Postgres.text(row["attempt_id"])}"','"true"'),
('retry_opt_in','lib/atheum/core.ex','not request["safe_retry"] -> {:error, :retry_disabled}',''),
('timeout_absence','lib/atheum/core.ex','def completion({:error, error}), do: {"unresolved", "unknown", nil, error}','def completion({:error, error}), do: {"failed", "confirmed_absent", nil, error}'),
('cancel_confirmation','lib/atheum.ex',"stop_confirmed=CASE WHEN status='accepted' THEN true ELSE stop_confirmed END","stop_confirmed=true"),
('acceptance_key','lib/atheum/postgres.ex','VALUES(#{text(invocation)},#{text(execution)},#{text(key)},','VALUES(#{text(invocation)},#{text(execution)},#{text(key <> id())},'),
('request_identity','lib/atheum.ex',"status='running',attempt_id=","request=jsonb_set(request,'{apply,request_id}',#{Postgres.value(Postgres.id())}),status='running',attempt_id=")]
report=[]
for name,file,old,new in mutations:
    if len(sys.argv)>1 and name!=sys.argv[1]: continue
    dest=pathlib.Path(tempfile.mkdtemp(prefix='atheum-mutant-'+name+'-'))
    for n in ['lib','test','priv','scripts','.githooks']: shutil.copytree(w/n,dest/n)
    for n in ['mix.exs','.formatter.exs','.gitignore']: shutil.copy2(w/n,dest/n)
    p=dest/file; original=p.read_text(); assert original.count(old)==1,(name,original.count(old)); p.write_text(original.replace(old,new))
    cmd=['mix','test','--include','integration','--seed','20261002']
    r=subprocess.run(cmd,cwd=dest,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (v/(name+'.raw')).write_text(r.stdout)
    report.append(dict(name=name,file=file,old=old,new=new,workspace=str(dest),command=cmd,exit=r.returncode,compile_failure='Compilation error' in r.stdout))
    print(name,r.returncode,flush=True)
    (v/('mutations-'+sys.argv[1]+'.json' if len(sys.argv)>1 else 'mutations.json')).write_text(json.dumps(report,indent=2)+'\n')
