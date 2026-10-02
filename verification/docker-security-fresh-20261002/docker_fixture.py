#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root=Path(os.environ['FRESH_FIXTURE'])
with (root/'argv.raw').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\n')
if sys.argv[1] in ['inspect', 'image']: print((root/'response.json').read_text())
elif sys.argv[1]=='create': print('a'*64)
elif sys.argv[1]=='rm': print('removed')
