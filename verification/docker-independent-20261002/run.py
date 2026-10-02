import subprocess,os,time,json,pathlib,shutil,hashlib
root=pathlib.Path('/Users/tonton/Documents/workspace/alaya/atheum'); out=root/'verification/docker-independent-20261002'; base=pathlib.Path('/tmp/atheum-docker-independent-20261002')
env=dict(os.environ,ATHEUM_TEST_PG_URL='postgres://postgres@127.0.0.1:55440/atheum_docker_independent_20261002',AKASHIC_BINARY='/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic')
records=[]
def run(name,cmd,cwd):
 t=time.time()
 with (out/(name+'.raw')).open('w') as f:
  p=subprocess.run(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=180)
 records.append(dict(name=name,command=cmd,cwd=str(cwd),exit=p.returncode,start_unix=t,seconds=time.time()-t))
 (out/'executions.json').write_text(json.dumps(records,indent=2))
 print(name,p.returncode,flush=True)
 return p.returncode
if not base.exists():
 base.mkdir()
 for d in ['lib','priv','worker','test']: shutil.copytree(root/d,base/d)
 ebin=base/'_build/test/lib/atheum/ebin';ebin.mkdir(parents=True)
 assert run('baseline-compile',['elixirc','-o',str(ebin)]+[str(p) for p in (base/'lib').rglob('*.ex')],base)==0
run('final-real',['elixir','-pa',str(base/'_build/test/lib/atheum/ebin'),'-r',str(out/'independent_test.exs'),'-r',str(base/'test/worker_integration_test.exs'),'-e',''],base)
s= (out/'independent_test.exs').read_text(); start=s.index('  test '); setup=s[:start]; tests=s[start:s.rfind('\nend')].split('\n  test '); tests=[tests[0]]+['  test '+x for x in tests[1:]]
mutations=[('stale_fence','lib/atheum.ex','"generation=#{row["generation"]} AND attempt_id=#{Postgres.text(row["attempt_id"])}"','"true"','late worker result'),('false_absence','lib/atheum.ex','Core.completion(outcome)','{"stopped", "confirmed_absent", nil, nil}','independent receipt model'),('release_unknown_create','lib/atheum/worker/manager.ex','not is_nil(instance["container_id"]) and Docker.absent?(instance, config)','Docker.absent?(instance, config)','unknown create absent')]
for name,file,old,new,selector in mutations:
 c=pathlib.Path('/tmp/atheum-mutation-'+name+'-20261002');c.mkdir(exist_ok=False)
 for d in ['lib','priv','worker']:shutil.copytree(base/d,c/d)
 p=c/file; text=p.read_text();assert text.count(old)==1,(name,text.count(old));p.write_text(text.replace(old,new))
 (out/(name+'.patch.json')).write_text(json.dumps(dict(file=file,old=old,new=new,before_sha256=hashlib.sha256(text.encode()).hexdigest(),after_sha256=hashlib.sha256(p.read_bytes()).hexdigest()),indent=2))
 ebin=c/'_build/test/lib/atheum/ebin';ebin.mkdir(parents=True)
 assert run(name+'-compile',['elixirc','-o',str(ebin)]+[str(p) for p in (c/'lib').rglob('*.ex')],c)==0
 chosen=[t for t in tests if selector in t.split('\n')[0]];assert len(chosen)==1,(selector,[t[:80] for t in tests])
 t=out/(name+'_test.exs');t.write_text(setup+chosen[0]+'\nend\n')
 run(name,['elixir','-pa',str(ebin),str(t)],c)
