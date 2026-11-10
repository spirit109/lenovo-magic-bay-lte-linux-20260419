#!/usr/bin/env python3
"""Bounded, passive macOS LTE recorder; no modem control or network writes."""
import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
BACKEND = "/usr/local/libexec/magic-bay-lte-v2/mbim-net"
PROXY = "/usr/local/libexec/magic-bay-lte-v2/magicbay-proxy-compat"
RUNTIME = Path("/var/run/magic-bay-lte-v2")
STOP = False


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def run(args, timeout=4):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"})
        return result.returncode, result.stdout, result.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return -1, "", type(exc).__name__


def root_file(path):
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            return None
        with path.open("rb") as stream:
            if info.st_size > 131072:
                # Connection identity lives at the start; fresh telemetry lives
                # at the end. Tail-only reads lose the interface as logs grow.
                head = stream.read(65536).rsplit(b"\n", 1)[0]
                stream.seek(-131072, os.SEEK_END)
                tail = stream.read(131072).partition(b"\n")[2]
                return (head + b"\n[bounded log gap]\n" + tail).decode("utf-8", errors="replace")
            return stream.read(131072).decode("utf-8", errors="replace")
    except OSError:
        return None


def interface_from_log(log, backend):
    if not backend or not re.search(r"^MBIM_NET ready=1 pid=" + str(backend["pid"]) + r"\b", log, re.MULTILINE):
        return None
    states = re.findall(r"^MBIM_NET active=([01])(?: utun=(utun\d+))?", log, re.MULTILINE)
    return states[-1][1] if states and states[-1][0] == "1" and states[-1][1] else None


def proxy_url(endpoint):
    if type(endpoint) is int:  # Existing explicit local-port callers.
        endpoint = {"scheme": "http", "host": "127.0.0.1", "port": endpoint}
    if not isinstance(endpoint, dict):
        return None
    scheme, host, port = (endpoint.get(k) for k in ("scheme", "host", "port"))
    if scheme not in ("http", "socks5h") or type(port) is not int or not 1 <= port <= 65535:
        return None
    if not isinstance(host, str) or "%" in host:
        return None
    if host.lower() == "localhost":
        return f"{scheme}://localhost:{port}"
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return None
    if not address.is_loopback:
        return None
    host = "[" + str(address) + "]" if address.version == 6 else str(address)
    return f"{scheme}://{host}:{port}"


def effective_proxy_state(companion, config_exit, config_text):
    result = {**companion, "companion_port": companion.get("port"),
              "port": None, "endpoint": None, "coverage": "unknown", "reason": None}
    if config_exit != 0:
        result["reason"] = "system_proxy_inventory_unavailable"
        return result
    values = {key: value.strip() for key, value in re.findall(
        r"^\s*([A-Za-z0-9]+)\s*:\s*([^\n]+)$", config_text, re.MULTILINE)}
    if any(values.get(k) == "1" for k in ("ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable")):
        result["reason"] = "automatic_proxy_route_not_evaluated"
        return result
    if values.get("HTTPSEnable") == "1":
        prefix, scheme = "HTTPS", "http"
    elif values.get("SOCKSEnable") == "1":
        prefix, scheme = "SOCKS", "socks5h"
    else:
        result["coverage"] = "direct_only"
        return result
    try:
        endpoint = {"scheme": scheme, "host": values[prefix + "Proxy"].strip(),
                    "port": int(values[prefix + "Port"])}
    except (KeyError, ValueError):
        result["reason"] = "invalid_system_proxy_endpoint"
        return result
    if not proxy_url(endpoint):
        result["reason"] = "unsupported_or_non_loopback_system_proxy"
        return result
    result.update(endpoint=endpoint, port=endpoint["port"], coverage="direct_and_proxy",
                  source="system_" + prefix.lower() + "_proxy")
    return result


def core():
    rc, output, _ = run(["/bin/ps", "-axo", "pid=,uid=,lstart=,comm="])
    inventory_known = rc == 0
    processes = []
    if rc == 0:
        for line in output.splitlines():
            parts = line.split(None, 7)
            if len(parts) == 8 and parts[7] == BACKEND:
                processes.append({"pid": int(parts[0]), "uid": int(parts[1]),
                                  "started": " ".join(parts[2:7]), "executable": parts[7]})
    pid_text = root_file(RUNTIME / "mbim-net.pid")
    backend = next((p for p in processes if p["uid"] == 0 and pid_text and
                    str(p["pid"]) == pid_text.strip()), None) if len(processes) == 1 else None
    log = root_file(RUNTIME / "mbim-net.log") or ""
    interface = interface_from_log(log, backend)
    errors = [line[:500] for line in log.splitlines()
              if re.match(r"^(USB bulk .*failed:|USB bulk .*short write:|SEND_ENCAPSULATED_COMMAND failed:|"
                          r"GET_ENCAPSULATED_RESPONSE failed:|MBIM_CONNECT .*failed:|"
                          r"select\(utun\) failed:|read\(utun\) failed:)", line)]
    address = None
    counters = None
    if interface:
        _, data, _ = run(["/sbin/ifconfig", interface])
        match = re.search(r"\binet ([0-9.]+)", data)
        address = match.group(1) if match else None
        _, data, _ = run(["/usr/sbin/netstat", "-ibn", "-I", interface])
        for line in data.splitlines():
            parts = line.split()
            if len(parts) >= 10 and parts[0] == interface and parts[2].startswith("<Link#"):
                try:
                    counters = {"rx_bytes": int(parts[5]), "tx_bytes": int(parts[8])}
                except ValueError:
                    pass
    _, route, _ = run(["/sbin/route", "-n", "get", "default"])
    route_fields = dict(re.findall(r"(gateway|interface):\s*(\S+)", route))
    usb = []
    try:
        data = subprocess.check_output(["/usr/sbin/ioreg", "-p", "IOUSB", "-a", "-l"], timeout=4)
        tree = plistlib.loads(data)
        todo = tree if isinstance(tree, list) else [tree]
        while todo:
            node = todo.pop()
            if not isinstance(node, dict):
                continue
            if node.get("idVendor") == 0x17ef and node.get("idProduct") == 0x7240:
                usb.append({"registry_id": node.get("IORegistryEntryID"),
                            "location_id": node.get("locationID")})
            children = node.get("IORegistryEntryChildren", [])
            todo.extend(children if isinstance(children, list) else [children])
        usb_known = True
    except (OSError, subprocess.TimeoutExpired, plistlib.InvalidFileException):
        usb_known = False
    rc, data, _ = run([PROXY, "status"])
    try:
        proxy_raw = json.loads(data) if rc == 0 else {}
    except ValueError:
        proxy_raw = {}
    companion = {key: proxy_raw.get(key) for key in ["state", "pid", "backend_pid", "port"]}
    config_exit, config_text, _ = run(["/usr/sbin/scutil", "--proxy"])
    proxy = effective_proxy_state(companion, config_exit, config_text)
    return {"at": now(), "process_inventory_known": inventory_known,
            "backend": backend, "backend_count": len(processes), "interface": interface, "address": address,
            "default": route_fields, "usb_known": usb_known, "usb": usb,
            "proxy": proxy, "traffic": counters, "usb_errors": errors}


def identity(sample):
    proxy = sample.get("proxy", {})
    return [sample.get(k) for k in ["backend", "interface", "address", "default"]] + [
        proxy.get("endpoint"), proxy.get("coverage")]


def probe(interface, proxy_port):
    results = []
    routes = []
    if interface:
        routes.append(("lte_direct", ["--interface", "if!" + interface, "--proxy", "", "--noproxy", "*"],
                       "https://www.apple.com/library/test/success.html"))
    selected_proxy = proxy_url(proxy_port)
    if selected_proxy:
        routes.append(("proxy_https", ["--proxy", selected_proxy, "--noproxy", ""],
                       "https://www.apple.com/library/test/success.html"))
    for label, options, url in routes:
        args = ["/usr/bin/curl", "--disable", "--silent", "--show-error", "--connect-timeout", "4",
                "--max-time", "7", "--output", "/dev/null", "--write-out", "%{http_code} %{time_total}"]
        rc, out, err = run(args + options + [url], timeout=9)
        values = out.strip().split()
        code = int(values[0]) if values and values[0].isdigit() else 0
        results.append({"path": label, "http": code, "curl_exit": rc,
                        "seconds": float(values[1]) if len(values) == 2 else None,
                        "error": err.strip()[:200], "passed": rc == 0 and 200 <= code < 400})
    return results


def stop(*_):
    global STOP
    STOP = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--duration", type=int, default=7200)
    parser.add_argument("--interval", type=int, default=10)
    parser.add_argument("--probe-interval", type=int, default=60)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    directory = Path(args.output).resolve()
    if ROOT not in directory.parents or args.duration not in range(1, 14401) or args.interval < 5:
        raise SystemExit("invalid bounded monitor arguments")
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    started = time.time()
    deadline = started + args.duration
    metadata = {"observer_pid": os.getpid(), "started_at": now(),
                "ends_at": dt.datetime.fromtimestamp(deadline, dt.timezone.utc).isoformat(timespec="seconds"),
                "duration_seconds": args.duration, "sample_interval": args.interval,
                "https_interval": args.probe_interval, "read_only": True,
                "backend_sha256": hashlib.sha256(Path(BACKEND).read_bytes()).hexdigest()}
    (directory / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
    previous = None
    last_probe = 0
    failed_rounds = 0
    samples = 0
    alarms = 0
    with (directory / "samples.jsonl").open("x") as records, (directory / "events.jsonl").open("x") as events:
        while not STOP and time.time() < deadline:
            sample = core()
            alerts = []
            if previous:
                if previous["backend"] and not sample["process_inventory_known"]:
                    alerts.append("process_inventory_unavailable")
                elif previous["backend"] and not sample["backend"]:
                    alerts.append("backend_disappeared_or_identity_unverified")
                elif previous["backend"] and sample["backend"] != previous["backend"]:
                    alerts.append("backend_identity_changed")
                if previous["usb"] and sample["usb_known"] and not sample["usb"]:
                    alerts.append("usb_device_disappeared")
                if previous["usb"] and sample["usb"] and sample["usb"] != previous["usb"]:
                    alerts.append("usb_device_reenumerated_or_replugged")
                if sample["usb_errors"] != previous["usb_errors"] and sample["usb_errors"]:
                    alerts.append("new_usb_errors")
                if previous["default"] != sample["default"]:
                    alerts.append("default_route_changed")
            if sample["backend"] and time.time() - last_probe >= args.probe_interval:
                results = probe(sample["interface"], sample["proxy"].get("endpoint"))
                after = core()
                sample["https"] = {"results": results, "identity_stable": identity(sample) == identity(after)}
                if (sample["https"]["identity_stable"] and sample["proxy"].get("coverage") != "unknown"
                        and results and all(p["curl_exit"] >= 0 for p in results)
                        and not any(p["passed"] for p in results)):
                    failed_rounds += 1
                else:
                    failed_rounds = 0
                if failed_rounds == 3:
                    alerts.append("all_https_paths_failed_three_rounds")
                last_probe = time.time()
            sample["https_failed_rounds"] = failed_rounds
            sample["alerts"] = alerts
            records.write(json.dumps(sample, ensure_ascii=False) + "\n"); records.flush()
            for alert in alerts:
                events.write(json.dumps({"at": sample["at"], "event": alert, "sample": sample}, ensure_ascii=False) + "\n")
                alarms += 1
            events.flush()
            samples += 1
            previous = sample
            (directory / "latest.json").write_text(json.dumps(sample, ensure_ascii=False, indent=2))
            (directory / "status.json").write_text(json.dumps({**metadata, "state": "running", "samples": samples,
                                                                "events": alarms, "latest_at": sample["at"]}, indent=2))
            if args.once:
                break
            for _ in range(args.interval):
                if STOP or time.time() >= deadline:
                    break
                time.sleep(1)
    (directory / "status.json").write_text(json.dumps({**metadata, "state": "stopped" if STOP else "completed",
                                                        "samples": samples, "events": alarms, "finished_at": now()}, indent=2))
    print(json.dumps({"monitor_directory": str(directory), "samples": samples, "events": alarms}))


if __name__ == "__main__":
    main()
