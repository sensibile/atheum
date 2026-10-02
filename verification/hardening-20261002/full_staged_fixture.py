"""Run the real staged-project gate without changing the original Git index."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
output = Path(__file__).resolve().parent
index = root / ".git/index"
before = hashlib.sha256(index.read_bytes()).hexdigest() if index.exists() else None
with tempfile.TemporaryDirectory(prefix="atheum-full-staged-") as directory:
    fixture = Path(directory)
    names = ["mix.exs", "mix.lock", ".formatter.exs", ".gitignore", ".githooks", "scripts", "lib", "priv", "test"]
    for name in names:
        source = root / name
        if source.is_dir():
            shutil.copytree(source, fixture / name)
        else:
            shutil.copy2(source, fixture / name)
    env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
    def run(*args):
        subprocess.run(args, cwd=fixture, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    run("git", "init", "-q")
    run("git", "config", "--local", "core.hooksPath", ".githooks")
    run("git", "add", "--", *names)
    for name in ["deps", ".cache", "artifacts"]:
        (fixture / name).symlink_to(root / name, target_is_directory=True)
    fixture_before = hashlib.sha256((fixture / ".git/index").read_bytes()).hexdigest()
    result = subprocess.run(["git", "hook", "run", "pre-commit"], cwd=fixture, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    fixture_after = hashlib.sha256((fixture / ".git/index").read_bytes()).hexdigest()
    (output / "full-staged-hook.log").write_text(result.stdout)
    after = hashlib.sha256(index.read_bytes()).hexdigest() if index.exists() else None
    report = {"exit_code": result.returncode, "fixture_index_unchanged": fixture_before == fixture_after,
              "actual_index_unchanged": before == after, "commits": False}
    (output / "full-staged-hook.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    if result.returncode or not report["fixture_index_unchanged"] or not report["actual_index_unchanged"]:
        raise SystemExit(1)
