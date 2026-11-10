"""Synthetic transactions/watchdog; never calls rootctl or opens USB."""
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("trial", ROOT / "resources/diagnostic-trial.py")
trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trial)


def fixture_worker(folder):
    @contextmanager
    def fake_lock(name):
        yield
    def fake_rollback(session, reason):
        trial.save(session / "fixture-rollback.json", {"reason": reason, "no_system_changes": True})
        (session / "done").touch()
        return 0
    trial.operation_lock = fake_lock
    trial.rollback = fake_rollback
    trial.watchdog(folder)


def main():
    source = Path(sys.argv[1]).resolve()
    output = ROOT / "_RecycleBin" / ("diagnostic-rollback-selftest-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
    output.mkdir(mode=0o700)
    target = output / "fixture-backend"
    shutil.copyfile(str(source / "mbim-net-original"), str(target))
    moved = []
    moved.append(trial.swap_file(source / "mbim-net-diagnostic", target, output, trial.CANDIDATE))
    assert trial.digest(target) == trial.CANDIDATE
    moved.append(trial.swap_file(source / "mbim-net-original", target, output, trial.STABLE))
    assert trial.digest(target) == trial.STABLE
    try:
        trial.swap_file(source / "mbim-net-diagnostic", target, output, trial.CANDIDATE, fail_after_move=True)
        raise AssertionError("failure injection did not occur")
    except RuntimeError as error:
        assert str(error) == "synthetic transaction failure"
    assert trial.digest(target) == trial.STABLE
    print("PASS synthetic install, restore and interrupted replacement restore exact original bytes", flush=True)
    proofs = []
    for mode in ("deadline", "parent_exit"):
        folder = output / mode
        folder.mkdir(mode=0o700)
        parent = subprocess.Popen([sys.executable, "-c", "import time; print('ready', flush=True); time.sleep(30)"],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        guard = None
        try:
            assert parent.stdout.readline().strip() == "ready"
            trial.save(folder / "manifest.json", {"parent": trial.identity(parent.pid),
                       "deadline": time.monotonic() + (2 if mode == "deadline" else 10)})
            guard = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--worker", str(folder)],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                     text=True, start_new_session=True)
            for _ in range(40):
                if (folder / "watchdog-ready.json").exists():
                    break
                time.sleep(0.05)
            assert (folder / "watchdog-ready.json").exists()
            if mode == "parent_exit":
                parent.terminate()
                parent.wait(timeout=3)
            guard.wait(timeout=7)
            assert guard.returncode == 0, guard.stderr.read()
            proof = json.loads((folder / "fixture-rollback.json").read_text())
            assert proof["reason"] == ("deadline" if mode == "deadline" else "parent_exited")
            if mode == "deadline":
                parent.wait(timeout=3)
            proofs.append(proof)
            print("PASS independent rollback dispatch: " + mode, flush=True)
        finally:
            if guard is not None and guard.poll() is None:
                guard.terminate()
                guard.wait(timeout=3)
            if parent.poll() is None:
                parent.terminate()
                parent.wait(timeout=3)
    trial.save(output / "results.json", {"passed": True, "scope": "fixtures and own sleep processes only",
               "archived_fixture_files": moved, "watchdog_dispatch": proofs,
               "installed_component_changed": False, "network_changed": False})
    print(json.dumps({"output": str(output), "passed": True, "archived_fixture_files": moved}))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        fixture_worker(Path(sys.argv[2]))
    else:
        main()
