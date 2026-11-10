"""Offline Linux-status script checks using mocked command output only."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve()
PUBLIC_ROOT = HERE.parents[1]
if (PUBLIC_ROOT / "check_modem_status.sh").is_file():
    ROOT = PUBLIC_ROOT
    SCRIPT = ROOT / "check_modem_status.sh"
else:
    ROOT = HERE.parents[2]
    SCRIPT = ROOT / "docs/publication/check_modem_status.sh"
FIXTURE_ROOT = ROOT / "dist"
FIXTURE_ROOT.mkdir(exist_ok=True)
FIXTURES = Path(tempfile.mkdtemp(prefix="linux-status-fixtures-", dir=FIXTURE_ROOT))
COMMANDS = {
    "lsusb": "printf '%s\\n' 'Bus 001 Device 002: ID 17ef:7240 Lenovo _SN:fixture-secret'\n",
    "nmcli": "printf '%s\\n' 'wwan0 gsm connected'\n",
    "ip": "printf '%s\\n' 'default via 192.0.2.1 dev wwan0'\n",
    "mmcli": """if [ "$1" = '-L' ]; then
  case "$MOCK_MODE" in
    one) printf '%s\\n' '/org/freedesktop/ModemManager1/Modem/7 [Lenovo] _SN:fixture-secret' ;;
    multiple) printf '%s\\n' '/org/freedesktop/ModemManager1/Modem/7 [A]' '/org/freedesktop/ModemManager1/Modem/12 [B]' ;;
    none) printf '%s\\n' 'No modems were found' ;;
  esac
else
  printf '%s\\n' "$*" >> "$TASK_CALLS"
  printf '%s\\n' 'modem.generic.state: connected' 'modem.generic.signal-quality.value: 77' 'modem.generic.equipment-identifier: 123456789012345'
fi
""",
}

for name, body in COMMANDS.items():
    path = FIXTURES / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


class StatusScript(unittest.TestCase):
    def run_case(self, mode):
        calls = FIXTURES / (mode + ".calls")
        env = dict(os.environ, PATH=str(FIXTURES) + ":/usr/bin:/bin", MOCK_MODE=mode, TASK_CALLS=str(calls))
        result = subprocess.run(["/bin/bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout, calls.read_text() if calls.exists() else ""

    def test_one_modem_uses_discovered_index_and_filters_identifiers(self):
        output, calls = self.run_case("one")
        self.assertIn("-m 7 --output-keyvalue", calls)
        self.assertIn("modem.generic.state: connected", output)
        self.assertNotIn("123456789012345", output)
        self.assertNotIn("fixture-secret", output)
        self.assertNotIn("192.0.2.1", output)
        self.assertIn("wwan0", output)

    def test_multiple_modems_do_not_query_an_arbitrary_index(self):
        output, calls = self.run_case("multiple")
        self.assertIn("Multiple modems", output)
        self.assertEqual(calls, "")

    def test_no_modem_is_reported_without_a_query(self):
        output, calls = self.run_case("none")
        self.assertIn("No modem index found", output)
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
