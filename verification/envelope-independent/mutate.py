import pathlib,json,subprocess,hashlib
out=pathlib.Path(__file__).parent; meta=json.loads((out/'preservation.json').read_text());root=pathlib.Path(meta['copy']);p=root/'lib/atheum/wire.ex';orig=p.read_text();mutated=orig.replace('{["ok", "result"], true, 0}', '{["ok", "result"], true, 2}')
assert mutated!=orig
p.write_text(mutated)
r=subprocess.run(['mix','test','test/independent_test.exs','--exclude','integration'],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
(out/'mutation-exit.raw').write_text(r.stdout);(out/'mutation-exit.exit').write_text(str(r.returncode)+'\n');(out/'mutation.json').write_text(json.dumps({'command':['mix','test','test/independent_test.exs','--exclude','integration'],'copy':str(root),'mutation':'success exit 0 -> 2','source_before':hashlib.sha256(orig.encode()).hexdigest(),'source_mutated':hashlib.sha256(mutated.encode()).hexdigest(),'detected':r.returncode!=0},indent=2));p.write_text(orig)
