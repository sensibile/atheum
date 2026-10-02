import pathlib, subprocess, hashlib, json, shutil, os, tempfile
src=pathlib.Path.cwd(); out=src/'verification/envelope-independent'; copy=pathlib.Path(tempfile.mkdtemp(prefix='atheum-envelope-'))
def hashes():
 files=list(src.glob('lib/**/*.ex'))+list(src.glob('test/**/*'))+list(src.glob('scripts/*'))+[src/'mix.exs',src/'mix.lock',src/'.githooks/pre-commit']
 files += [p for p in (src/'verification').rglob('*') if p.is_file() and out not in p.parents]
 idx=subprocess.check_output(['git','rev-parse','--git-path','index'],text=True).strip(); p=pathlib.Path(idx); p=p if p.is_absolute() else src/p
 if p.exists(): files.append(p)
 binary=pathlib.Path('/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic');files.append(binary)
 return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}
(out/'before-hashes.json').write_text(json.dumps(hashes(),indent=2))
for name in ['lib','test','priv','scripts','.githooks','deps','.cache']:
 if (src/name).exists(): shutil.copytree(src/name,copy/name)
for name in ['mix.exs','mix.lock','.formatter.exs']:
 shutil.copy2(src/name,copy/name)
shutil.copy2(out/'independent_test.exs',copy/'test/independent_test.exs')
commands=[]
def run(name,args,cwd=copy,env=None):
 r=subprocess.run(args,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 (out/(name+'.raw')).write_text(r.stdout);(out/(name+'.exit')).write_text(str(r.returncode)+'\n');commands.append({'name':name,'argv':args,'cwd':str(cwd),'exit':r.returncode});(out/'commands.json').write_text(json.dumps(commands,indent=2));return r
pg=['psql','-h','127.0.0.1','-p','55440','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
db='atheum_envelope_'+os.urandom(5).hex()
r=run('create-db',pg+['-c','CREATE DATABASE '+db])
env={**os.environ,'ATHEUM_TEST_PG_URL':'postgres://postgres@127.0.0.1:55440/'+db,'AKASHIC_BINARY':'/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic'}
# Existing test explicitly asserts this DB name; adapt only the isolated copy's assertion.
p=copy/'test/cycle_integration_test.exs';p.write_text(p.read_text().replace('assert {:ok, "atheum_cycle_test"}', 'assert {:ok, "'+db+'"}'))
run('format-independent',['mix','format','test/independent_test.exs'],env=env)
run('format-independent-second',['mix','format','test/independent_test.exs'],env=env)
shutil.copy2(copy/'test/independent_test.exs',out/'independent_test.exs')
run('precommit',['scripts/check','precommit'],env=env)
if r.returncode==0:
 run('review',['scripts/check','review'],env=env)
 run('independent',['mix','test','test/independent_test.exs','--include','integration','--trace'],env=env)
 run('drop-db',pg+['-c','DROP DATABASE '+db])
run('hook',['scripts/check-hook'],env=env)
(out/'after-hashes.json').write_text(json.dumps(hashes(),indent=2));(out/'preservation.json').write_text(json.dumps({'unchanged':json.loads((out/'before-hashes.json').read_text())==hashes(),'copy':str(copy),'db':db},indent=2))
