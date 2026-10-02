from pathlib import Path
import tempfile,shutil,subprocess,os,json,hashlib
source=Path.cwd(); out=source/'verification/final-independent'
env={**os.environ,'HEX_HOME':str(source/'.cache/hex'),'GIT_OPTIONAL_LOCKS':'0'}
records=[]
def run(root,name,cmd):
 p=subprocess.run(cmd,cwd=root,env=env,capture_output=True,text=True,timeout=180)
 with (out/(name+'.raw')).open('a') as f: f.write('$ '+repr(cmd)+'\n'+p.stdout+p.stderr)
 records.append({'name':name,'command':cmd,'exit':p.returncode})
 return p

def copy(root):
 for name in ['lib','test','priv','scripts','.githooks']:
  shutil.copytree(source/name,root/name)
 for name in ['mix.exs','mix.lock','.formatter.exs','.gitignore']:
  shutil.copy2(source/name,root/name)
 for name in ['deps','.cache','artifacts']:
  (root/name).symlink_to(source/name,target_is_directory=True)
with tempfile.TemporaryDirectory(prefix='atheum-final-hook-') as tmp:
 root=Path(tmp);copy(root)
 run(root,'fixture-init',['git','init','-q'])
 run(root,'fixture-stage',['git','add','lib','test','priv','scripts','.githooks','mix.exs','mix.lock','.formatter.exs','.gitignore'])
 idx=root/'.git/index'
 def hook(name,expected):
  before=hashlib.sha256(idx.read_bytes()).hexdigest()
  p=run(root,name,['git','-c','core.hooksPath=.githooks','hook','run','pre-commit'])
  after=hashlib.sha256(idx.read_bytes()).hexdigest()
  assert before==after
  assert (p.returncode==0)==expected
  records[-1].update(index_before=before,index_after=after)
 hook('hook-valid-full-staged',True)
 file=root/'lib/atheum.ex'; original=file.read_text()
 file.write_text(original+'\nTHIS IS BROKEN ELIXIR\n')
 run(root,'fixture-stage-broken',['git','add','lib/atheum.ex'])
 hook('hook-clean-broken-staged',False)
 file.write_text(original)
 hook('hook-broken-staged-fixed-working',False)
 for name,rel,old,new in [
  ('unknown','lib/atheum/core.ex','{"unresolved", "unknown", nil, error}','{"failed", "confirmed_absent", nil, error}'),
  ('success','lib/atheum/wire.ex','if apply_result?(result, request["expected_version"]), do: {:ok, result}, else: failure()','_ = request; {:ok, result}'),
  ('url','lib/atheum/postgres.ex','query: nil,','query: _ignored,')]:
  with tempfile.TemporaryDirectory(prefix='atheum-final-mutation-') as mutation_tmp:
   mutant=Path(mutation_tmp); copy(mutant)
   shutil.copy2(out/'sensitivity_test.exs',mutant/'test/final_sensitivity_test.exs')
   file=mutant/rel; content=file.read_text();assert content.count(old)==1
   file.write_text(content.replace(old,new))
   (out/(name+'.patch.json')).write_text(json.dumps({'file':rel,'old':old,'new':new},indent=2))
   p=run(mutant,'mutation-'+name,['mix','test','test/final_sensitivity_test.exs','--trace'])
   assert p.returncode!=0 and 'Failed: 1 test' in p.stdout
(out/'isolated-results.json').write_text(json.dumps(records,indent=2))
print(json.dumps(records,indent=2))
