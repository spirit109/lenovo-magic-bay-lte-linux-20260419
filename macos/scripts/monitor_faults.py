#!/usr/bin/env python3
"""Bounded, passive fault bundles. Never opens USB or changes network state."""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

import monitor_lte as base

STOP = False
SITES = [("apple", "https://www.apple.com/library/test/success.html"),
         ("baidu", "https://www.baidu.com/"),
         ("cloudflare", "https://cp.cloudflare.com/generate_204")]
DIAG_KEYS = {"ts", "pid", "kind", "ok", "rssi", "error_rate", "register_state",
             "packet_service_state", "activation_state", "nw_error", "rx_packets",
             "tx_packets", "rx_bytes", "tx_bytes", "rx_timeouts", "rx_errors",
             "tx_errors", "parse_drops", "last_rx_ms", "last_tx_ms", "cid", "rc",
             "rsrp", "rsrq", "rssnr", "rsrp_dbm", "rsrq_db", "rssnr_db",
             "rsrp_dbm_limit", "rsrq_db_limit", "rssnr_db_limit"}


def save(path, value):
    # Atomic generated-state update; readers never confuse a partial JSON write
    # with a connectivity failure. No pre-existing user file is replaced.
    pending = path.with_name(path.name + ".pending")
    pending.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    os.replace(pending, path)


def signal_evidence(sample, log, epoch):
    pid = (sample.get("backend") or {}).get("pid")
    diagnostics = []
    for line in log.splitlines():
        if not line.startswith("MBIM_DIAG "):
            continue
        try:
            raw = json.loads(line[len("MBIM_DIAG "):])
            clean = {k: v for k, v in raw.items() if k in DIAG_KEYS and
                     (isinstance(v, (int, float, bool)) or k == "kind" and isinstance(v, str))}
            if (clean.get("pid") == pid and isinstance(clean.get("ts"), (int, float))
                    and -2 <= epoch - clean["ts"] <= 60
                    and clean.get("kind") in ("signal", "signal_ext", "registration", "packet", "data")):
                diagnostics.append(clean)
        except (TypeError, ValueError):
            pass
    radio = next((x for x in reversed(diagnostics) if x.get("kind") == "signal"), None)
    quality = next((x for x in reversed(diagnostics) if x.get("kind") == "signal_ext"), None)
    quality_ranges = {"rsrp_dbm": (-140, -43), "rsrq_db": (-19.5, -2.5), "rssnr_db": (-5, 30)}
    quality_known = quality and quality.get("ok") and all(
        type(quality.get(key)) in (int, float) and low <= quality[key] <= high
        for key, (low, high) in quality_ranges.items())
    cached = re.findall(r"^\s+rssi=(\d+) error_rate=(\d+)", log, re.MULTILINE)
    cache_owned = pid and re.search(r"MBIM_NET ready=1 pid=" + str(pid) + r"\b", log)
    radio_known = radio and radio.get("ok") and type(radio.get("rssi")) is int and 0 <= radio["rssi"] <= 31
    return {"live_radio": radio,
            "live_signal_quality": quality,
            "signal_quality_state": "ready" if quality_known else "unknown",
            "live_radio_state": "ready" if radio_known else "unknown",
            "reason": None if radio_known else "no_fresh_known_backend_radio_value",
            "connection_time_cache": ({"rssi": int(cached[-1][0]),
                                       "error_rate": int(cached[-1][1]),
                                       "live": False} if cached and cache_owned else None),
            "backend_diagnostics": diagnostics[-24:]}


def observe():
    sample = base.core()
    log = base.root_file(base.RUNTIME / "mbim-net.log") or ""
    sample["radio"] = signal_evidence(sample, log, time.time())
    return sample


def probe_one(spec):
    name, url, path, interface, port = spec
    selected_proxy = base.proxy_url(port) if path == "proxy" else None
    if path == "proxy" and selected_proxy is None:
        return {"site": name, "path": path, "curl_exit": -1, "metrics": {},
                "error": "system_proxy_path_unknown_or_unsupported", "passed": False}
    route = (["--proxy", "", "--noproxy", "*", "--interface", "if!" + interface]
             if path == "direct" else ["--proxy", selected_proxy, "--noproxy", ""])
    fmt = ('{"http":"%{http_code}","dns_s":%{time_namelookup},'
           '"tcp_s":%{time_connect},"tls_s":%{time_appconnect},"total_s":%{time_total}}')
    rc, stdout, stderr = base.run(["/usr/bin/curl", "--disable", "--ipv4", "--silent",
        "--show-error", "--connect-timeout", "4", "--max-time", "7", "--max-filesize",
        "65536", "--output", "/dev/null", "--write-out", fmt] + route + [url], timeout=9)
    try:
        metrics = json.loads(stdout)
    except ValueError:
        metrics = {}
    code = metrics.get("http", "000")
    return {"site": name, "path": path, "curl_exit": rc, "metrics": metrics,
            "error": stderr.strip()[:200], "passed": rc == 0 and code.isdigit() and 200 <= int(code) < 400}


def probes(sample):
    if not sample.get("backend") or not sample.get("interface"):
        return []
    proxy = sample.get("proxy", {})
    port = proxy.get("endpoint")
    paths = ["direct"] + (["proxy"] if base.proxy_url(port) or proxy.get("coverage") == "unknown" else [])
    specs = [(name, url, path, sample["interface"], port)
             for name, url in SITES for path in paths]
    with ThreadPoolExecutor(max_workers=6) as pool:
        return list(pool.map(probe_one, specs))


def all_failed(results, path=None):
    rows = [r for r in results if path is None or r["path"] == path]
    # Unknown/missing observations are never treated as a measured outage.
    return (len(rows) >= 3 and all(isinstance(r.get("curl_exit"), int) and
            r["curl_exit"] >= 0 and r.get("metrics") for r in rows) and
            not any(r["passed"] for r in rows))


def transitions(previous, current):
    if not previous:
        return []
    changes = []
    if current["process_inventory_known"]:
        if previous["backend"] and not current["backend"]:
            changes.append("backend_exited_or_identity_unverified")
        elif previous["backend"] and previous["backend"] != current["backend"]:
            changes.append("backend_identity_changed")
    if current["usb_known"]:
        if previous["usb"] and not current["usb"]:
            changes.append("usb_disappeared")
        elif previous["usb"] != current["usb"] and current["usb"]:
            changes.append("usb_enumeration_changed")
    if current["default"] != previous["default"]:
        changes.append("default_route_changed")
    if current["usb_errors"] and current["usb_errors"] != previous["usb_errors"]:
        changes.append("new_usb_error")
    return changes


def fault_extras(folder):
    fields = {}
    for key, args in [("dns", ["scutil", "--dns"]), ("proxy", ["scutil", "--proxy"]),
                      ("tcp_counters", ["netstat", "-s", "-p", "tcp"])]:
        rc, out, _ = base.run(args, timeout=5)
        fields[key] = {"exit": rc, "output": out[:24000]}
    rc, raw, _ = base.run(["nettop", "-P", "-L", "3", "-d", "-x", "-s", "2",
                          "-J", "bytes_in,bytes_out", "-n"], timeout=9)
    # Process summaries only: no peer addresses, request bodies or packet data.
    fields["process_traffic"] = {"exit": rc, "includes_loopback": True, "csv": raw[:32000]}
    save(folder / "extras.json", fields)


def main():
    global STOP
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--duration", type=int, default=14400)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    folder = Path(args.output).resolve()
    if base.ROOT not in folder.parents or not 1 <= args.duration <= 14400:
        raise SystemExit("Use a new project-local output and at most four hours")
    folder.mkdir(mode=0o700, parents=True, exist_ok=False)
    def stop(signum, frame):
        global STOP
        STOP = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    started, deadline = time.time(), time.time() + args.duration
    metadata = {"observer_pid": os.getpid(), "started_at": base.now(),
                "ends_at": dt.datetime.fromtimestamp(deadline, dt.timezone.utc).isoformat(),
                "duration_seconds": args.duration, "sample_interval": 5,
                "https_interval": 20, "read_only": True,
                "backend_sha256": hashlib.sha256(Path(base.BACKEND).read_bytes()).hexdigest(),
                "radio_requires_backend_telemetry": True}
    save(folder / "metadata.json", metadata)
    status = {**metadata, "state": "starting", "samples": 0, "events": 0,
              "faults": 0, "https_passed": 0, "https_attempted": 0,
              "live_radio_state": "unknown"}
    save(folder / "status.json", status)
    ring, previous, last_probe, failures = deque(maxlen=30), None, 0, 0
    count, event_count, fault_count, passed, attempted = 0, 0, 0, 0, 0
    pending = []
    with ThreadPoolExecutor(max_workers=1) as extras_pool, \
            (folder / "samples.jsonl").open("x") as samples, \
            (folder / "events.jsonl").open("x") as events:
        while not STOP and time.time() < deadline:
            sample = observe()
            changes = transitions(previous, sample)
            triggers = list(changes)
            if sample["backend"] and time.time() - last_probe >= 20:
                rows = probes(sample)
                after = observe()
                stable = base.identity(sample) == base.identity(after)
                sample["https"] = {"results": rows, "identity_stable": stable}
                attempted += sum(r["curl_exit"] >= 0 for r in rows)
                passed += sum(r["passed"] for r in rows)
                failures = failures + 1 if stable and all_failed(rows) else 0
                if stable and failures == 1:
                    triggers.append("multiple_sites_all_measured_paths_failed")
                elif stable and failures == 3:
                    changes.append("all_measured_https_failed_three_rounds")
                if stable and failures == 0:
                    for path in ("direct", "proxy"):
                        if all_failed(rows, path):
                            triggers.append(path + "_multiple_sites_failed")
                last_probe = time.time()
            sample["https_failed_rounds"] = failures
            sample["alerts"] = changes
            if triggers and (not pending or changes):
                fault_count += 1
                target = folder / ("fault-%04d" % fault_count)
                target.mkdir(mode=0o700)
                save(target / "trigger.json", {"at": sample["at"], "triggers": triggers,
                     "sample": sample, "note": "Changes may be manual; not an automatic software-fault diagnosis"})
                save(target / "before.json", list(ring))
                pending.append((target, time.time() + 60))
                extras_pool.submit(fault_extras, target)
            for change in changes:
                event_count += 1
                events.write(json.dumps({"id": event_count, "at": sample["at"],
                             "event": change, "fault_count": fault_count, "sample": sample}, ensure_ascii=False) + "\n")
            events.flush()
            for target, until in pending:
                with (target / "after.jsonl").open("a") as stream:
                    stream.write(json.dumps(sample, ensure_ascii=False) + "\n")
            pending = [(target, until) for target, until in pending if time.time() < until]
            samples.write(json.dumps(sample, ensure_ascii=False) + "\n")
            samples.flush()
            ring.append(sample)
            previous = sample
            count += 1
            status = {**metadata, "state": "running", "samples": count, "events": event_count,
                      "faults": fault_count, "https_passed": passed, "https_attempted": attempted,
                      "latest_at": sample["at"], "live_radio_state": sample["radio"]["live_radio_state"]}
            save(folder / "latest.json", sample)
            save(folder / "status.json", status)
            if args.once:
                break
            for _ in range(5):
                if STOP or time.time() >= deadline:
                    break
                time.sleep(1)
    save(folder / "status.json", {**status, "state": "stopped" if STOP else "completed",
         "finished_at": base.now(), "elapsed_seconds": round(time.time() - started)})
    print(json.dumps({"output": str(folder), "samples": count, "events": event_count,
                      "faults": fault_count, "https_passed": passed, "https_attempted": attempted}))


if __name__ == "__main__":
    main()
