#!/usr/bin/env python3
import json, os, subprocess, sys
with open(os.environ['FRESH_DOCKER_ARGV'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\n')
sys.exit(subprocess.call(['/usr/local/bin/docker', *sys.argv[1:]]))
