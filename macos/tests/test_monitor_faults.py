"""Evidence gates only; no modem, process controls or network requests."""
import json
from io import BytesIO
from pathlib import Path
import stat
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import monitor_faults as monitor


class EvidenceGates(unittest.TestCase):
    def test_extended_quality_is_fresh_bound_and_unknown_aware(self):
        frame = {"kind": "signal_ext", "pid": 10, "ts": 100, "ok": True,
                 "rsrp_dbm": -98.0, "rsrq_db": -9.0, "rssnr_db": 8.0}
        def read(value, epoch=100):
            return monitor.signal_evidence({"backend": {"pid": 10}}, "MBIM_DIAG " + json.dumps(value), epoch)
        self.assertEqual(read(frame)["signal_quality_state"], "ready")
        self.assertEqual(read(frame, 161)["signal_quality_state"], "unknown")
        self.assertEqual(read({**frame, "pid": 11})["signal_quality_state"], "unknown")
        for value in (None, True, 1000):
            self.assertEqual(read({**frame, "rsrp_dbm": value})["signal_quality_state"], "unknown")

    def test_idle_companion_does_not_hide_actual_https_proxy(self):
        proxy = monitor.base.effective_proxy_state({"state": "idle", "port": None}, 0,
            "HTTPSEnable : 1\nHTTPSProxy : 127.0.0.1\nHTTPSPort : 7890\n")
        self.assertEqual(proxy["coverage"], "direct_and_proxy")
        self.assertEqual(monitor.base.proxy_url(proxy["endpoint"]), "http://127.0.0.1:7890")
        with patch.object(monitor, "probe_one", return_value={}) as probe:
            rows = monitor.probes({"backend": {"pid": 10}, "interface": "utun4", "proxy": proxy})
        self.assertEqual(len(rows), 6)
        self.assertEqual(sum(call.args[0][2] == "proxy" for call in probe.call_args_list), 3)

    def test_socks_and_ipv6_loopback_use_explicit_proxy_protocol(self):
        proxy = monitor.base.effective_proxy_state({}, 0,
            "SOCKSEnable : 1\nSOCKSProxy : ::1\nSOCKSPort : 7891\n")
        with patch.object(monitor.base, "run", return_value=(0, '{"http":"204"}', "")) as run:
            result = monitor.probe_one(("fixture", "https://example.invalid/", "proxy", None, proxy["endpoint"]))
        self.assertTrue(result["passed"])
        self.assertIn("socks5h://[::1]:7891", run.call_args.args[0])

    def test_unknown_proxy_never_becomes_a_measured_outage(self):
        for code, text in [(1, ""), (0, "ProxyAutoConfigEnable : 1\n"),
                           (0, "HTTPSEnable : 1\nHTTPSProxy : 192.0.2.1\nHTTPSPort : 7890\n")]:
            proxy = monitor.base.effective_proxy_state({}, code, text)
            self.assertEqual(proxy["coverage"], "unknown")
            with patch.object(monitor.base, "run", return_value=(28, '{"http":"000"}', "timeout")) as run:
                rows = monitor.probes({"backend": {"pid": 10}, "interface": "utun4", "proxy": proxy})
            self.assertEqual(run.call_count, 3)  # Direct public tests only; no guessed proxy request.
            self.assertEqual(len(rows), 6)
            self.assertFalse(monitor.all_failed(rows))
            self.assertTrue(monitor.all_failed(rows, "direct"))

    def test_proxy_changes_invalidate_probe_identity(self):
        old = {"proxy": monitor.base.effective_proxy_state({}, 0,
               "HTTPSEnable : 1\nHTTPSProxy : localhost\nHTTPSPort : 7890\n")}
        new = {"proxy": monitor.base.effective_proxy_state({}, 0,
               "HTTPSEnable : 1\nHTTPSProxy : localhost\nHTTPSPort : 7891\n")}
        self.assertNotEqual(monitor.base.identity(old), monitor.base.identity(new))
        self.assertIsNone(monitor.base.proxy_url({"scheme": "http", "host": "127.0.0.1@invalid", "port": 7890}))
        self.assertIsNone(monitor.base.proxy_url({"scheme": "http", "host": "127.0.0.1", "port": 65536}))

    def test_large_log_keeps_connection_identity_and_current_telemetry(self):
        header = b"MBIM_NET active=1 utun=utun4\nMBIM_NET ready=1 pid=10\n"
        latest = b'MBIM_DIAG {"ts":100,"pid":10,"kind":"signal","ok":true,"rssi":30}\n'
        raw = header + b"old telemetry\n" * 20000 + latest
        path = Mock()
        path.lstat.return_value = SimpleNamespace(st_mode=stat.S_IFREG | 0o644,
                                                  st_uid=0, st_size=len(raw))
        path.open.return_value = BytesIO(raw)
        log = monitor.base.root_file(path)
        self.assertLessEqual(len(log.encode()), 65536 + 131072 + 32)
        self.assertIn(latest.decode().strip(), log)
        interface = monitor.base.interface_from_log(log, {"pid": 10})
        self.assertEqual(interface, "utun4")
        with patch.object(monitor, "probe_one", return_value={}) as probe:
            self.assertEqual(len(monitor.probes({"backend": {"pid": 10},
                "interface": interface, "proxy": {}})), 3)
            self.assertTrue(all(call.args[0][3] == "utun4" for call in probe.call_args_list))

    def test_interface_requires_matching_ready_process(self):
        log = "MBIM_NET active=1 utun=utun4\nMBIM_NET ready=1 pid=10\n"
        self.assertIsNone(monitor.base.interface_from_log(log, {"pid": 11}))
        self.assertIsNone(monitor.base.interface_from_log(log, None))

    def test_released_interface_is_not_probed(self):
        log = "MBIM_NET active=1 utun=utun4\nMBIM_NET ready=1 pid=10\nMBIM_NET active=0\n"
        self.assertIsNone(monitor.base.interface_from_log(log, {"pid": 10}))

    def test_connection_cache_is_never_live(self):
        result = monitor.signal_evidence({"backend": {"pid": 10}},
            "  rssi=30 error_rate=99\nMBIM_NET ready=1 pid=10\n", 100)
        self.assertEqual(result["live_radio_state"], "unknown")
        self.assertFalse(result["connection_time_cache"]["live"])

    def test_radio_is_bound_to_current_process_and_freshness(self):
        def line(pid, ts, rssi):
            return "MBIM_DIAG " + json.dumps({"pid": pid, "ts": ts, "kind": "signal",
                "ok": True, "rssi": rssi, "device_id": "must-not-be-copied"}) + "\n"
        sample = {"backend": {"pid": 10}}
        for text in (line(11, 100, 30), line(10, 1, 30), line(10, 100, 99)):
            self.assertEqual(monitor.signal_evidence(sample, text, 100)["live_radio_state"], "unknown")
        result = monitor.signal_evidence(sample, line(10, 100, 30), 100)
        self.assertEqual(result["live_radio_state"], "ready")
        self.assertNotIn("device_id", result["live_radio"])

    def test_single_site_failure_is_not_whole_path_failure(self):
        rows = [{"path": "direct", "passed": x, "curl_exit": 0 if x else 28,
                 "metrics": {"http": "200" if x else "000"}} for x in [False, True, True]]
        self.assertFalse(monitor.all_failed(rows))
        rows[1]["passed"] = rows[2]["passed"] = False
        self.assertTrue(monitor.all_failed(rows))

    def test_missing_observation_is_not_an_outage(self):
        rows = [{"path": "direct", "passed": False, "curl_exit": -1, "metrics": {}}
                for _ in range(3)]
        self.assertFalse(monitor.all_failed(rows))
        self.assertFalse(monitor.all_failed([]))

    def test_unknown_usb_inventory_is_not_unplugging(self):
        old = {"process_inventory_known": True, "backend": {"pid": 10}, "usb_known": True,
               "usb": [{"registry_id": 1}], "default": {"interface": "utun4"}, "usb_errors": []}
        current = {**old, "process_inventory_known": False, "backend": None,
                   "usb_known": False, "usb": []}
        self.assertEqual(monitor.transitions(old, current), [])
        current["usb_known"] = True
        self.assertIn("usb_disappeared", monitor.transitions(old, current))


if __name__ == "__main__":
    unittest.main()
