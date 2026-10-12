"""Drive the send window without a display, against a stand-in for omdrop."""
import importlib
import os
import shutil
from pathlib import Path
import stat
import sys
import tempfile
import unittest

TMP = tempfile.mkdtemp()
FAKE = Path(TMP, "omdrop")
# A build sandbox has no /usr/bin/env.
BASH = shutil.which("bash")
FAKE.write_text(f"#!{BASH}\n" + r'''echo "$*" >> "$FAKE_LOG"
case "$1" in
  status) echo "{\"visible\": $(cat "$FAKE_STATE/visible")}" ;;
  on) [ -e "$FAKE_STATE/on-fails" ] && { echo "Wi-Fi is switched off." >&2; exit 1; }
      echo true > "$FAKE_STATE/visible" ;;
  off) echo false > "$FAKE_STATE/visible" ;;
  peers)
    [ -e "$FAKE_STATE/nobody" ] && { echo "No devices found yet." >&2; exit 1; }
    echo '{"mac": "aa:bb:cc:dd:ee:01", "rssi": null, "name": null}'
    echo '{"mac": "aa:bb:cc:dd:ee:02", "rssi": -40, "name": "Gabriel iPhone"}'
    echo 'not json'
    echo '{"mac": "aa:bb:cc:dd:ee:01", "rssi": null, "name": "Kitchen iPad"}'
    trap 'echo "peers stopped" >> "$FAKE_LOG"; exit 130' TERM
    sleep 30 & wait ;;
  send)
    echo "Sending..."
    [ -e "$FAKE_STATE/declined" ] && { echo "The device declined the transfer." >&2; exit 1; }
    exit 0 ;;
esac
''')
FAKE.chmod(FAKE.stat().st_mode | stat.S_IXUSR)
NOTIFY = Path(TMP, "notify-send")
NOTIFY.write_text(f'#!{BASH}\n' + 'echo "notify $*" >> "$FAKE_LOG"\n')
NOTIFY.chmod(NOTIFY.stat().st_mode | stat.S_IXUSR)
os.environ.update(OMDROP=str(FAKE), OMDROP_NOTIFY_SEND=str(NOTIFY))

sys.path.insert(0, str(Path(__file__).resolve().parent))
omdrop_send = importlib.import_module("omdrop_send")
omdrop_send.SEARCH_AGAIN_MS = 50

from PyQt6.QtTest import QTest
from PyQt6.QtWidgets import QApplication, QDialog

APP = QApplication.instance() or QApplication([])


class SendDialogTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.state = Path(self.dir.name, "state")
        self.state.mkdir()
        self.log = Path(self.dir.name, "log")
        self.log.touch()
        os.environ.update(FAKE_LOG=str(self.log), FAKE_STATE=str(self.state))
        self.visible(False)
        self.files = [str(Path(self.dir.name, n)) for n in ("a photo.jpg", "-b.txt")]
        for f in self.files:
            Path(f).write_text("x")
        self.dialog = None

    def tearDown(self):
        if self.dialog is not None and self.dialog.state != "done":
            self.dialog.reject()
        self.wait(lambda: False, 100)
        self.dir.cleanup()

    def visible(self, yes):
        (self.state / "visible").write_text("true" if yes else "false")

    def calls(self):
        return self.log.read_text().splitlines()

    def wait(self, condition, timeout=5000):
        waited = 0
        while not condition() and waited < timeout:
            QTest.qWait(20)
            waited += 20
        return condition()

    def open(self, confirm=True):
        self.dialog = omdrop_send.SendDialog(self.files)
        self.dialog.confirm_turning_on = lambda: confirm
        self.dialog.show()
        self.dialog.begin()
        return self.dialog

    def listed(self):
        return self.names() == ["Kitchen iPad", "Gabriel iPhone"]

    def names(self):
        d = self.dialog.devices
        return [d.item(i).text() for i in range(d.count())]

    def test_lists_devices_as_they_answer_and_sends_to_the_chosen_one(self):
        self.visible(True)
        d = self.open()
        self.assertTrue(self.wait(self.listed))
        # The first to give a name is preselected.
        self.assertEqual(d.devices.currentItem().text(), "Gabriel iPhone")
        self.assertTrue(d.send_button.isEnabled())
        d.send_button.click()
        self.assertTrue(self.wait(lambda: d.result() == QDialog.DialogCode.Accepted and d.state == "done"))
        self.assertTrue(self.wait(lambda: any(c.startswith("notify") for c in self.calls())))
        calls = self.calls()
        self.assertIn("peers -n --json --stream", calls)
        self.assertIn("send --to aa:bb:cc:dd:ee:02 -- " + " ".join(self.files), calls)
        self.assertLess(calls.index("peers stopped"), next(i for i, c in enumerate(calls) if c.startswith("send")))
        self.assertIn("notify -a AirDrop -i document-send Sent 2 files to Gabriel iPhone", calls)
        # It was on before the window opened, so it stays on.
        self.assertNotIn("on", calls)
        self.assertNotIn("off", calls)

    def test_turns_omdrop_on_first_and_off_again_afterwards(self):
        d = self.open()
        self.assertTrue(self.wait(self.listed))
        d.send_button.click()
        self.assertTrue(self.wait(lambda: "off" in self.calls()))
        calls = self.calls()
        self.assertLess(calls.index("on"), calls.index("peers -n --json --stream"))
        self.assertGreater(calls.index("off"), next(i for i, c in enumerate(calls) if c.startswith("send")))

    def test_declining_to_turn_it_on_closes_the_window(self):
        d = self.open(confirm=False)
        self.assertTrue(self.wait(lambda: d.result() == QDialog.DialogCode.Rejected and d.state == "done"))
        self.assertEqual(self.calls(), ["status --json"])

    def test_failing_to_turn_on_says_why_and_offers_nothing_to_send_to(self):
        (self.state / "on-fails").touch()
        d = self.open()
        self.assertTrue(self.wait(lambda: d.state == "failed"))
        self.assertIn("Wi-Fi is switched off.", d.status.text())
        self.assertFalse(d.send_button.isEnabled())
        d.reject()
        self.assertNotIn("off", self.calls())

    def test_cancelling_stops_the_lookup_and_gives_the_radio_back(self):
        d = self.open()
        self.assertTrue(self.wait(self.listed))
        d.reject()
        self.assertTrue(self.wait(lambda: "off" in self.calls()))
        self.assertIn("peers stopped", self.calls())
        self.assertFalse(any(c.startswith("send") for c in self.calls()))

    def test_keeps_looking_while_nobody_answers(self):
        self.visible(True)
        (self.state / "nobody").touch()
        d = self.open()
        self.assertTrue(self.wait(lambda: self.calls().count("peers -n --json --stream") >= 3))
        self.assertIn("No devices found yet.", d.status.text())
        self.assertFalse(d.send_button.isEnabled())
        (self.state / "nobody").unlink()
        self.assertTrue(self.wait(self.listed))

    def test_a_refused_send_says_why_and_can_be_tried_again(self):
        self.visible(True)
        (self.state / "declined").touch()
        d = self.open()
        self.assertTrue(self.wait(self.listed))
        d.send_button.click()
        self.assertTrue(self.wait(lambda: "Not sent" in d.status.text()))
        self.assertIn("The device declined the transfer.", d.status.text())
        self.assertTrue(d.isVisible())
        self.assertTrue(self.wait(lambda: self.calls().count("peers -n --json --stream") >= 2))
        self.assertIn("Not sent", d.status.text())
        (self.state / "declined").unlink()
        self.assertTrue(d.send_button.isEnabled())
        d.send_button.click()
        self.assertTrue(self.wait(lambda: d.result() == QDialog.DialogCode.Accepted and d.state == "done"))

    def test_screenshot(self):
        out = os.environ.get("OMDROP_SEND_SCREENSHOT")
        if not out:
            self.skipTest("OMDROP_SEND_SCREENSHOT is not set")
        self.visible(True)
        d = self.open()
        self.assertTrue(self.wait(self.listed))
        d.grab().save(out)


if __name__ == "__main__":
    unittest.main()
