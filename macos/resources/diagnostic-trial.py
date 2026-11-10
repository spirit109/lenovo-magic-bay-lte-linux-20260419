#!/usr/bin/python3
"""macOS-only, explicitly authorized backend trial and stable-version recovery.

Run from the generated, signed diagnostic app with /usr/bin/python3 -I.
No installation, login item, network action or root operation occurs on import.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

STABLE = "587e96ae0f505181e615b6dfa76f07624cc30603c598b2c75eefaed235d067ca"
CANDIDATE = "0d33d6f3fd204fcbc3f411b4c91426a0cf296c425d9f91f16257388b2cc31fb0"
TARGET = Path("/usr/local/libexec/magic-bay-lte-v2/mbim-net")
CONTROLLER = "/usr/local/sbin/magic-bay-lte-v2-rootctl"
RUNTIME = Path("/var/run/magic-bay-lte-v2")
RESOURCES = Path(__file__).resolve().parent
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1"}


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("component is not a regular file")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    pending = path.with_name(path.name + ".pending")
    pending.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    os.replace(str(pending), str(path))


def project():
    root = Path((RESOURCES / "project-root.txt").read_text().strip()).resolve()
    if not (root / "AGENTS.md").is_file() or not (root / "backend/mbim_net.c").is_file():
        raise RuntimeError("project root unavailable")
    return root


def identity(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "pid=,uid=,lstart=,comm="],
                            capture_output=True, text=True, timeout=3, env=ENV)
    values = result.stdout.strip().split(None, 7)
    return {"pid": int(values[0]), "uid": int(values[1]), "start": " ".join(values[2:7]),
            "exe": values[7]} if result.returncode == 0 and len(values) == 8 else None


def preflight(allow_missing=False):
    for name, expected in [("mbim-net-original", STABLE), ("mbim-net-diagnostic", CANDIDATE)]:
        path = RESOURCES / name
        if digest(path) != expected:
            raise RuntimeError("packaged component hash mismatch")
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)],
                       check=True, capture_output=True, env=ENV)
    for directory in (TARGET.parent, Path(CONTROLLER).parent, RUNTIME):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError("unsafe system directory")
    if TARGET.is_symlink():
        raise RuntimeError("unsafe backend symbolic link")
    if TARGET.exists() and (TARGET.stat().st_uid != 0 or TARGET.stat().st_mode & 0o022):
        raise RuntimeError("unsafe installed component ownership or permissions")
    installed = digest(TARGET) if TARGET.exists() else None
    if installed not in (STABLE, CANDIDATE) and not (allow_missing and installed is None):
        raise RuntimeError("another component version is installed; refusing replacement")
    if project().stat().st_dev != TARGET.parent.stat().st_dev:
        raise RuntimeError("project recycle and backend must share a filesystem")
    return installed


def current_apn():
    result = subprocess.run(["/bin/ps", "-axo", "pid=,comm="], capture_output=True, text=True, env=ENV)
    pids = [line.split(None, 1)[0] for line in result.stdout.splitlines()
            if len(line.split(None, 1)) == 2 and line.split(None, 1)[1] == str(TARGET)]
    if len(pids) != 1:
        return None
    command = subprocess.check_output(["/bin/ps", "-p", pids[0], "-o", "command="], text=True, env=ENV)
    match = re.search(r"(?:^|\s)--apn=([A-Za-z0-9._-]{1,100})(?=\s|$)", command)
    return match[1] if match else None


@contextmanager
def operation_lock(name):
    fd = os.open(str(RUNTIME / name), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise RuntimeError("unsafe operation lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def run_ctl(session, *arguments):
    child = subprocess.Popen([CONTROLLER] + list(arguments), stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, env=ENV, start_new_session=True)
    save(session / "controller-child.json", identity(child.pid))
    try:
        output = child.communicate(timeout=55)[0]
    except subprocess.TimeoutExpired:
        child.terminate()
        child.wait(timeout=3)
        raise RuntimeError("controller timeout")
    save(session / ("controller-" + arguments[0] + "-" + uuid.uuid4().hex + ".json"),
         {"exit": child.returncode, "output": output[:3000]})
    return child.returncode, output


def no_backend():
    result = subprocess.run(["/bin/ps", "-axo", "comm="], capture_output=True, text=True, env=ENV)
    return result.returncode == 0 and not any(line.strip() == str(TARGET) for line in result.stdout.splitlines())


def swap_file(source, target, session, expected, fail_after_move=False):
    if digest(source) != expected:
        raise RuntimeError("replacement hash mismatch")
    stage = session / ("stage-" + uuid.uuid4().hex)
    shutil.copyfile(str(source), str(stage))
    os.chmod(str(stage), 0o755)
    if os.geteuid() == 0:
        os.chown(str(stage), 0, 0)
    archived = session / ("component-" + uuid.uuid4().hex)
    moved = False
    try:
        if target.exists():
            if digest(target) not in (STABLE, CANDIDATE):
                raise RuntimeError("target identity changed")
            os.rename(str(target), str(archived))
            moved = True
        if fail_after_move:
            raise RuntimeError("synthetic transaction failure")
        os.rename(str(stage), str(target))
        if digest(target) != expected:
            raise RuntimeError("installed bytes mismatch")
    except BaseException:
        if moved:
            if target.exists():
                os.rename(str(target), str(session / ("failed-" + uuid.uuid4().hex)))
            os.rename(str(archived), str(target))
        raise
    return str(archived) if moved else None


def replace(session, name, expected):
    run_ctl(session, "stop")
    for _ in range(25):
        if no_backend():
            break
        time.sleep(1)
    if not no_backend():
        raise RuntimeError("backend has not exited; refusing file replacement")
    with operation_lock("control.lock"):
        if not no_backend():
            raise RuntimeError("another connection started during maintenance")
        archived = swap_file(RESOURCES / name, TARGET, session, expected)
    save(session / ("replacement-" + uuid.uuid4().hex + ".json"),
         {"installed_hash": expected, "archived": archived})
    manifest_file = session / "manifest.json"
    apn = json.loads(manifest_file.read_text()).get("apn") if manifest_file.exists() else None
    if apn and re.fullmatch(r"[A-Za-z0-9._-]{1,100}", apn):
        return run_ctl(session, "start", apn)
    return 0, "component_restored_without_dialing; connect through Magic Bay UI"


def preserve_diagnostics(session):
    try:
        with (RUNTIME / "mbim-net.log").open() as source, (session / "telemetry-before-restore.jsonl").open("a") as target:
            for line in source:
                if line.startswith("MBIM_DIAG "):
                    target.write(line[len("MBIM_DIAG "):])
    except OSError:
        pass


def rollback(session, reason):
    if TARGET.exists() and digest(TARGET) not in (STABLE, CANDIDATE):
        raise RuntimeError("unknown live version; automatic rollback refused")
    preserve_diagnostics(session)
    code, output = replace(session, "mbim-net-original", STABLE)
    save(session / "rollback.json", {"reason": reason, "stable_hash_verified": digest(TARGET) == STABLE,
                                   "controller_exit": code, "output": output[:3000]})
    (session / "done").touch()
    return code


def watchdog(session):
    manifest = json.loads((session / "manifest.json").read_text())
    save(session / "watchdog-ready.json", {"pid": os.getpid(), "session": os.getsid(0)})
    while not (session / "done").exists():
        alive = identity(manifest["parent"]["pid"]) == manifest["parent"]
        expired = time.monotonic() >= manifest["deadline"]
        if expired or not alive:
            # Terminate only this trial's exact parent/controller, releasing its
            # locks; never kill an MBIM daemon or any unrelated process.
            if alive:
                os.kill(manifest["parent"]["pid"], signal.SIGTERM)
            child_file = session / "controller-child.json"
            if child_file.exists():
                child = json.loads(child_file.read_text())
                if child and child["exe"] == CONTROLLER and identity(child["pid"]) == child:
                    os.kill(child["pid"], signal.SIGTERM)
            time.sleep(1)
            try:
                with operation_lock("diagnostic-trial.lock"):
                    rollback(session, "deadline" if expired else "parent_exited")
            except Exception as error:
                save(session / "rollback-error.json", {"error": str(error), "manual_recovery_required": True})
            return
        time.sleep(0.5)


def healthy(session):
    _, output = run_ctl(session, "status")
    match = re.search(r"^interface=(utun\d+)$", output, re.MULTILINE)
    pid = re.search(r"^pid=(\d+)$", output, re.MULTILINE)
    if not match or not pid:
        return False
    log = (RUNTIME / "mbim-net.log").read_text(errors="replace")[-131072:]
    radio = []
    for line in log.splitlines():
        if line.startswith("MBIM_DIAG "):
            try:
                item = json.loads(line[10:])
                if (item.get("pid") == int(pid[1]) and item.get("kind") == "signal" and item.get("ok")
                        and 0 <= item.get("rssi", 99) <= 31 and 0 <= time.time() - item.get("ts", 0) < 30):
                    radio.append(item)
            except (ValueError, TypeError):
                pass
    if not radio:
        return False
    results = []
    for url in ("https://www.apple.com/library/test/success.html", "https://www.baidu.com/"):
        result = subprocess.run(["/usr/bin/curl", "--disable", "--ipv4", "--silent", "--show-error",
            "--noproxy", "*", "--proxy", "", "--interface", "if!" + match[1], "--connect-timeout", "4",
            "--max-time", "6", "--output", "/dev/null", "--write-out", "%{http_code}", url],
            capture_output=True, text=True, timeout=8, env=ENV)
        results.append(result.returncode == 0 and result.stdout in ("200", "204"))
    save(session / "health.json", {"at": time.time(), "radio": radio[-1], "direct_sites_passed": results})
    return all(results)


def main():
    if sys.platform != "darwin":
        raise SystemExit("This system adapter requires macOS")
    if len(sys.argv) < 2 or sys.argv[1] not in ("check", "trial", "restore", "watchdog"):
        raise SystemExit("check | trial | restore | watchdog SESSION")
    action = sys.argv[1]
    if action == "check":
        print(json.dumps({"installed_hash": preflight(), "candidate": CANDIDATE,
                          "stable": STABLE, "network_changed": False}))
        return
    if os.geteuid() != 0:
        raise SystemExit("administrator_required")
    if action == "watchdog":
        session = Path(sys.argv[2]).resolve()
        if session.parent != project() / "_RecycleBin" or session.stat().st_uid != 0 or session.is_symlink():
            raise SystemExit("unsafe trial session")
        watchdog(session)
        return
    preflight(allow_missing=action == "restore")
    session = project() / "_RecycleBin" / ("diagnostic-switch-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    session.mkdir(mode=0o700, parents=True)
    with operation_lock("diagnostic-trial.lock"):
        apn = current_apn()
        if action == "trial" and not apn:
            raise RuntimeError("active connection APN cannot be verified; network unchanged")
        save(session / "manifest.json", {"parent": identity(os.getpid()), "deadline": time.monotonic() + 120,
             "candidate": CANDIDATE, "stable": STABLE, "apn": apn})
        if action == "restore":
            if rollback(session, "manual") != 0:
                raise RuntimeError("stable component restored; reconnect needs checking")
            print("stable_restored=1 session=" + str(session))
            return
        with (session / "watchdog.log").open("x") as log:
            child = subprocess.Popen(["/usr/bin/python3", "-I", str(Path(__file__).resolve()), "watchdog", str(session)],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True, env=ENV)
        for _ in range(30):
            if (session / "watchdog-ready.json").exists():
                break
            if child.poll() is not None:
                raise RuntimeError("rollback watchdog failed before any network change")
            time.sleep(0.1)
        if not (session / "watchdog-ready.json").exists():
            raise RuntimeError("rollback watchdog not ready; network unchanged")
        try:
            replace(session, "mbim-net-diagnostic", CANDIDATE)
            deadline = json.loads((session / "manifest.json").read_text())["deadline"]
            while time.monotonic() < deadline - 15:
                if healthy(session):
                    (session / "done").touch()
                    child.wait(timeout=3)
                    print("diagnostic_active=1 rollback_entry_available=1 session=" + str(session))
                    return
                time.sleep(3)
            raise RuntimeError("fresh signal and direct HTTPS health gate not passed")
        except Exception:
            rollback(session, "trial_failed")
            child.wait(timeout=3)
            raise


if __name__ == "__main__":
    main()
