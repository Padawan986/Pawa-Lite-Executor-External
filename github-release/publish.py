"""Publish helper: stage the current inject payload, stamp version.json,
commit and push to the release repo. Run from anywhere:

    py github-release/publish.py 2026-09-14.1 "notes..."
    py github-release/publish.py 2026-09-14.1 --no-push   (stage only)

Requires: git + GitHub auth (gh CLI login is enough, plain git picks
up the stored credential).
"""
import datetime
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO_URL = "https://github.com/Padawan986/Pawa-Lite-Executor-External.git"
GIT_USER = "Padawan986"
GIT_EMAIL = "Padawan986@users.noreply.github.com"

ROOT = Path(__file__).resolve().parent
SRC_INIT = ROOT.parent / "src" / "FAPI" / "luau" / "init.luau"
SRC_BIN = ROOT.parent / "src" / "FAPI" / "luau" / "init.bin"
DST_INIT = ROOT / "init.luau"
DST_BIN = ROOT / "init.bin"
VERSION_FILE = ROOT / "version.json"
CLONE_DIR = ROOT / ".cache" / "relpush"
PUSH_FILES = ("version.json", "README.md", "init.luau", "init.bin")


def run_git(args, cwd, timeout=120):
    return subprocess.run(
        ["git"] + args, cwd=str(cwd), capture_output=True, text=True,
        timeout=timeout,
    )


def stage(version, notes):
    data = SRC_INIT.read_bytes()
    if len(data) < 1024 or b"identifyexecutor" not in data:
        print("source init.luau looks wrong, aborting")
        return None
    bindata = SRC_BIN.read_bytes()
    if len(bindata) < 8192:
        print("source init.bin looks wrong, aborting")
        return None
    shutil.copyfile(SRC_INIT, DST_INIT)
    shutil.copyfile(SRC_BIN, DST_BIN)
    print(f"staged init.bin ({len(bindata)} bytes)")
    info = json.loads(VERSION_FILE.read_text(encoding="utf-8"))
    info["init_version"] = version
    if notes:
        info["notes"] = notes
    VERSION_FILE.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    print(f"staged init {version} ({len(data)} bytes)")
    return version


def push(version):
    CLONE_DIR.parent.mkdir(parents=True, exist_ok=True)
    if not (CLONE_DIR / ".git").is_dir():
        r = run_git(["clone", REPO_URL, str(CLONE_DIR)], ROOT)
        if r.returncode != 0:
            print("clone failed:\n" + (r.stderr or r.stdout))
            return 1
    else:
        r = run_git(["fetch", "origin"], CLONE_DIR)
        if r.returncode != 0:
            print("fetch failed:\n" + (r.stderr or r.stdout))
            return 1
        r = run_git(["reset", "--hard", "origin/main"], CLONE_DIR)
        if r.returncode != 0:
            print("reset failed:\n" + (r.stderr or r.stdout))
            return 1

    for name in PUSH_FILES:
        src = ROOT / name
        if src.is_file():
            shutil.copyfile(src, CLONE_DIR / name)

    r = run_git(["add", *PUSH_FILES], CLONE_DIR)
    if r.returncode != 0:
        print("git add failed:\n" + (r.stderr or r.stdout))
        return 1
    r = run_git(["diff", "--cached", "--quiet"], CLONE_DIR)
    if r.returncode == 0:
        print("nothing new to push (remote already at this state)")
        return 0
    r = run_git(
        ["-c", f"user.name={GIT_USER}", "-c", f"user.email={GIT_EMAIL}",
         "commit", "-m", f"release {version}"],
        CLONE_DIR,
    )
    if r.returncode != 0:
        print("commit failed:\n" + (r.stderr or r.stdout))
        return 1
    r = run_git(["push", "origin", "main"], CLONE_DIR)
    if r.returncode != 0:
        print("push failed:\n" + (r.stderr or r.stdout))
        print("hint: git pull in the cache dir if someone else pushed meanwhile")
        return 1
    print(f"pushed release {version} to {REPO_URL}")
    return 0


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--no-push"]
    no_push = "--no-push" in sys.argv[1:]
    version = args[0] if len(args) > 0 else datetime.date.today().isoformat() + ".1"
    notes = args[1] if len(args) > 1 else ""
    if stage(version, notes) is None:
        return 1
    if no_push:
        print("staged only (--no-push)")
        return 0
    return push(version)


if __name__ == "__main__":
    raise SystemExit(main())
