#!/usr/bin/env python3
import hashlib,json,os,shutil,subprocess,tempfile,time
from pathlib import Path
repo=Path(__file__).resolve().parents[2]; out=Path(__file__).resolve().parent
psql='/opt/homebrew/opt/libpq/bin/psql'
db='atheum_security_fresh_'+str(int(time.time()))
root=Path(tempfile.mkdtemp(prefix='atheum-security-fresh-'))
env=dict(os.environ, FRESH_OUT=str(out), FRESH_ROOT=str(root), FRESH_DOCKER_ARGV=str(out/'docker-argv.raw'), ATHEUM_TEST_PG_URL='postgres://postgres@127.0.0.1:55440/'+db, AKASHIC_BINARY=str(repo.parent/'akashic/target/debug/akashic'), ATHEUM_SECRET_SENTINEL='ATHEUM_SECRET_SENTINEL=should-not-cross-container')
base=[psql,'-X','-w','-h','127.0.0.1','-p','55440','-U','postgres','-d','atheum_cycle_test','-v','ON_ERROR_STOP=1','-Atc']
created=False
suffix='-extended' if os.environ.get('FRESH_EXTENDED') else ''
with (out/('run'+suffix+'.raw')).open('w') as log:
 try:
  log.write('DEDICATED_DB '+db+'\nTEMP_ROOT '+str(root)+'\n'); log.flush()
  subprocess.run(base+['CREATE DATABASE '+db],check=True,stdout=log,stderr=log); created=True
  image=json.loads((repo/'worker/image.json').read_text())['image_id']
  with (out/'image-inspect.raw').open('w') as f: subprocess.run(['/usr/local/bin/docker','image','inspect',image],stdout=f,stderr=log,check=True)
  files=sorted(set(list((repo/'lib').rglob('*.ex'))+[repo/'priv/schema.sql',repo/'worker/Dockerfile',repo/'worker/main.exs',repo/'worker/image.json',repo/'scripts/build-worker',repo/'mix.lock']))
  hashes={str(f.relative_to(repo)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
  for f in [Path('/usr/local/bin/docker').resolve(),Path(env['AKASHIC_BINARY']),Path(psql).resolve(),Path(shutil.which('elixir')).resolve()]: hashes[str(f)]=hashlib.sha256(f.read_bytes()).hexdigest()
  (out/'hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
  args=[shutil.which('elixir')]
  for f in sorted((repo/'lib').rglob('*.ex')): args+=['-r',str(f)]
  args+=[str(out/('probe_extended.exs' if suffix else 'probe.exs'))]
  log.write('COMMAND '+json.dumps(args)+'\n');log.flush()
  result=subprocess.run(args,cwd=repo,env=env,stdout=log,stderr=log,timeout=160)
  log.write('EXIT '+str(result.returncode)+'\n');log.flush()
 finally:
  if created: subprocess.run(base+['DROP DATABASE '+db],stdout=log,stderr=log,check=True)
  shutil.rmtree(root)
  with (out/('remaining'+suffix+'.raw')).open('w') as f:
   f.write('our temporary root exists: '+str(root.exists())+'\n')
   subprocess.run(base+["SELECT datname FROM pg_database WHERE datname='"+db+"'"],stdout=f,stderr=f,check=True)
   subprocess.run(['/usr/local/bin/docker','ps','-a','--filter','label=org.acropolis.atheum.worker=supplier-set-active-v1','--format','{{.ID}} {{.Names}} {{.Status}}'],stdout=f,stderr=f,check=True)
