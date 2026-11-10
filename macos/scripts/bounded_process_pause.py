#!/usr/bin/env python3
"""Same-user, identity-bound temporary pause guard; never changes networking.

Pausing an existing user process requires task-specific authorization. Import
arm/pause/restore from a bounded experiment. The detached watchdog restores on
deadline or experiment-parent exit; it never stops a process by itself.
This adapter uses macOS ps/SIGSTOP/SIGCONT and is not a Windows implementation.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def snapshot(pid):
    result = subprocess.run(
        ["/bin/ps", "-p", str(int(pid)), "-o", "pid=,uid=,lstart=,stat=,comm="],
        capture_output=True, text=True, timeout=3)
    fields = result.stdout.strip().split(None, 8)
    if result.returncode or len(fields) != 9:
        return None
    return {"pid": int(fields[0]), "uid": int(fields[1]),
            "started": " ".join(fields[2:7]), "state": fields[7],
            "executable": fields[8]}


def same(expected, actual):
    return actual is not None and all(expected[k] == actual[k] for k in
                                      ("pid", "uid", "started", "executable"))


def save(path, value):
    # Generated evidence/state only; each experiment has its own private folder.
    with path.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def restore(folder, reason="experiment_finally"):
    folder = Path(folder).resolve()
    manifest = json.loads((folder / "manifest.json").read_text())
    target = manifest["target"]
    actual = snapshot(target["pid"])
    outcome = "identity_changed_or_exited"
    if same(target, actual):
        if "T" in actual["state"] and (folder / "stop-intended.json").exists():
            os.kill(target["pid"], signal.SIGCONT)
            outcome = "continued"
        else:
            outcome = "already_running_or_not_owned"
    save(folder / ("restore-" + reason + ".json"),
         {"reason": reason, "outcome": outcome, "target": target,
          "observed": actual, "monotonic": time.monotonic()})
    (folder / "done").touch()
    return outcome


def arm(folder, pid, max_seconds=60):
    folder = Path(folder).resolve()
    if ROOT not in folder.parents or not 1 <= max_seconds <= 120:
        raise ValueError("Use a new project-local guard folder and <=120 seconds")
    target, parent = snapshot(pid), snapshot(os.getpid())
    if not target or target["uid"] != os.getuid() or "T" in target["state"]:
        raise ValueError("Target must be a running process owned by this user")
    if pid == os.getpid():
        raise ValueError("Experiment must remain independent of the paused target")
    folder.mkdir(mode=0o700)
    save(folder / "manifest.json", {"target": target, "parent": parent,
         "deadline_monotonic": time.monotonic() + max_seconds})
    with (folder / "watchdog.log").open("w") as log:
        child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                 "watchdog", str(folder)],
                                stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                start_new_session=True, close_fds=True)
    for _ in range(40):
        if (folder / "ready.json").exists():
            return child
        if child.poll() is not None:
            break
        time.sleep(0.1)
    raise RuntimeError("Independent watchdog did not arm; target was not paused")


def pause(folder, watchdog):
    folder = Path(folder).resolve()
    manifest = json.loads((folder / "manifest.json").read_text())
    target = manifest["target"]
    actual = snapshot(target["pid"])
    if (watchdog.poll() is not None or time.monotonic() + 5 >=
            manifest["deadline_monotonic"] or not same(target, actual) or
            "T" in actual["state"]):
        raise RuntimeError("Pause safety check failed; target was not paused")
    save(folder / "stop-intended.json", {"target": target})
    os.kill(target["pid"], signal.SIGSTOP)


def watchdog(folder):
    folder = Path(folder).resolve()
    if ROOT not in folder.parents:
        raise ValueError("Guard folder outside project")
    manifest = json.loads((folder / "manifest.json").read_text())
    if manifest["target"]["uid"] != os.getuid():
        raise ValueError("Wrong target user")
    save(folder / "ready.json", {"pid": os.getpid(), "session": os.getsid(0)})
    def finish(signum, frame):
        restore(folder, "watchdog_signal")
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, finish)
    signal.signal(signal.SIGINT, finish)
    while not (folder / "done").exists():
        if time.monotonic() >= manifest["deadline_monotonic"]:
            restore(folder, "watchdog_deadline")
            return
        if not same(manifest["parent"], snapshot(manifest["parent"]["pid"])):
            restore(folder, "watchdog_parent_exit")
            return
        time.sleep(0.2)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "watchdog":
        watchdog(sys.argv[2])
    else:
        raise SystemExit("Library helper; watchdog is started only by arm()")
