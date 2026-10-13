"""Pick a nearby Apple device in a window and send it files.

    omdrop-send FILE...

What a file manager's "Send via AirDrop" entry runs. The window turns omdrop
on when it is off, lists devices as they answer with their names, sends to the
one chosen, and turns omdrop off again if it was the one to turn it on.
"""

import json
import os
import subprocess
import sys

from PyQt6.QtCore import QProcess, QSettings, Qt, QTimer
from PyQt6.QtGui import QIcon
from PyQt6.QtWidgets import (
    QApplication,
    QCheckBox,
    QDialog,
    QDialogButtonBox,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QProgressBar,
    QVBoxLayout,
)

OMDROP = os.environ.get("OMDROP", "omdrop")
NOTIFY_SEND = os.environ.get("OMDROP_NOTIFY_SEND", "notify-send")
ADDRESS = Qt.ItemDataRole.UserRole
# A lookup that ends without a choice is run again after this long.
SEARCH_AGAIN_MS = 1500
LOOKING = (
    "Looking for devices… On the iPhone or Mac, set AirDrop to Everyone and "
    "keep the screen on. Names take up to twenty seconds to arrive."
)


def describe(files):
    if len(files) == 1:
        return os.path.basename(files[0])
    return f"{len(files)} files"


class SendDialog(QDialog):
    def __init__(self, files):
        super().__init__()
        self.files = [os.path.abspath(f) for f in files]
        self.proc = None
        self.state = "idle"
        self.turned_on = False
        self.recipient = ""
        self.errors = []

        self.setWindowTitle("Send via AirDrop")
        self.setWindowIcon(QIcon.fromTheme("document-send"))
        self.resize(420, 360)

        self.heading = QLabel(f"Send {describe(self.files)} to:")
        self.devices = QListWidget()
        self.devices.itemSelectionChanged.connect(self.selection_changed)
        self.devices.itemActivated.connect(lambda _item: self.send())
        self.busy = QProgressBar()
        self.busy.setRange(0, 0)
        self.busy.setTextVisible(False)
        self.status = QLabel()
        self.status.setWordWrap(True)
        self.buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Cancel)
        self.send_button = self.buttons.addButton("Send", QDialogButtonBox.ButtonRole.AcceptRole)
        self.send_button.setIcon(QIcon.fromTheme("document-send"))
        self.send_button.setEnabled(False)
        self.buttons.accepted.connect(self.send)
        self.buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        for widget in (self.heading, self.devices, self.busy, self.status, self.buttons):
            layout.addWidget(widget)

    # ------------------------------------------------------------ processes

    def run(self, args, on_finished, on_output=None):
        """Start `omdrop ARGS`; its output goes to on_output a line at a time."""
        proc = QProcess(self)
        proc.setProgram(OMDROP)
        proc.setArguments(args)
        if on_output:
            proc.readyReadStandardOutput.connect(lambda: self.read_lines(proc, on_output))
        proc.readyReadStandardError.connect(lambda: self.read_errors(proc))
        proc.finished.connect(lambda code, _status: self.finished(proc, code, on_finished))
        proc.errorOccurred.connect(lambda error: self.not_started(proc, error))
        self.errors = []
        self.proc = proc
        proc.start()

    def read_lines(self, proc, on_output):
        while proc.canReadLine():
            line = bytes(proc.readLine()).decode(errors="replace").strip()
            if line:
                on_output(line)

    def read_errors(self, proc):
        text = bytes(proc.readAllStandardError()).decode(errors="replace")
        self.errors += [line.strip() for line in text.splitlines() if line.strip()]

    def finished(self, proc, code, on_finished):
        # One that was stopped to make room for the next has nothing to report.
        if proc is self.proc:
            self.proc = None
            on_finished(code)

    def not_started(self, proc, error):
        if proc is self.proc and error == QProcess.ProcessError.FailedToStart:
            self.proc = None
            self.fail(f"The omdrop command could not be started ({OMDROP}).")

    def stop_process(self):
        """End what is running. omdrop stops its own children on SIGTERM."""
        proc, self.proc = self.proc, None
        if proc is None or proc.state() == QProcess.ProcessState.NotRunning:
            return
        proc.terminate()
        if not proc.waitForFinished(5000):
            proc.kill()
            proc.waitForFinished(1000)

    # ---------------------------------------------------------------- steps

    def begin(self):
        """Turn omdrop on if it isn't, then look for devices."""
        if self.radio_on():
            self.search()
        elif self.confirm_turning_on():
            self.state = "starting"
            self.show_status("Turning AirDrop on…", busy=True)
            self.run(["on"], self.turned_on_finished)
        else:
            QTimer.singleShot(0, self.reject)

    def radio_on(self):
        try:
            out = subprocess.run(
                [OMDROP, "status", "--json"], capture_output=True, text=True, timeout=15
            ).stdout
            return json.loads(out).get("visible") is True
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return False

    def confirm_turning_on(self):
        settings = QSettings("omdrop", "send")
        if settings.value("turn-on-without-asking", False, type=bool):
            return True
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Icon.Question)
        box.setWindowTitle("Send via AirDrop")
        box.setText("Turn AirDrop on?")
        box.setInformativeText(
            "AirDrop uses this computer's Wi-Fi card. With some cards, Intel's "
            "among them, Wi-Fi is disconnected until AirDrop is off again, "
            "which happens when this window closes."
        )
        dont_ask = QCheckBox("Don't ask again")
        box.setCheckBox(dont_ask)
        turn_on = box.addButton("Turn On", QMessageBox.ButtonRole.AcceptRole)
        box.addButton(QMessageBox.StandardButton.Cancel)
        box.exec()
        if box.clickedButton() is not turn_on:
            return False
        if dont_ask.isChecked():
            settings.setValue("turn-on-without-asking", True)
        return True

    def turned_on_finished(self, code):
        if code != 0:
            self.fail("AirDrop could not be turned on.")
            return
        self.turned_on = True
        self.search()

    def search(self, quiet=False):
        """Look for devices. A repeat is quiet: it leaves the status line be."""
        self.state = "searching"
        self.devices.setEnabled(True)
        self.selection_changed()
        if not quiet:
            self.show_status(LOOKING, busy=True)
        self.run(["peers", "-n", "--json", "--stream"], self.search_finished, self.peer_found)

    def peer_found(self, line):
        try:
            peer = json.loads(line)
            address, name = peer["mac"], peer.get("name")
        except (ValueError, KeyError, TypeError):
            return
        item = next(
            (self.devices.item(i) for i in range(self.devices.count())
             if self.devices.item(i).data(ADDRESS) == address),
            None,
        )
        if item is None:
            item = QListWidgetItem(QIcon.fromTheme("smartphone"), "")
            item.setData(ADDRESS, address)
            # The first device replaces omdrop's advice on finding one.
            if not self.devices.count() and self.busy.isVisible():
                self.show_status(LOOKING, busy=True)
            self.devices.addItem(item)
        # A later answer without a name doesn't take away one already given.
        if name or not item.text():
            item.setText(name or f"Unnamed device ({address})")
        if name and not self.devices.selectedItems():
            self.devices.setCurrentItem(item)

    def search_finished(self, _code):
        # A lookup with nobody in range ends at once with omdrop's own advice.
        if self.errors and not self.devices.count():
            self.show_status(self.errors[-1] + " Still looking…", busy=True)
        QTimer.singleShot(SEARCH_AGAIN_MS, self.search_again)

    def search_again(self):
        if self.state == "searching" and self.proc is None:
            self.search(quiet=True)

    def selection_changed(self):
        self.send_button.setEnabled(
            self.state == "searching" and bool(self.devices.selectedItems())
        )

    def send(self):
        items = self.devices.selectedItems()
        if self.state != "searching" or not items:
            return
        self.recipient = items[0].text()
        address = items[0].data(ADDRESS)
        # The lookup announces over Bluetooth for as long as it runs.
        self.stop_process()
        self.state = "sending"
        self.devices.setEnabled(False)
        self.selection_changed()
        self.show_status(f"Sending to {self.recipient}… Accept it on the device.", busy=True)
        self.run(
            ["send", "--to", address, "--", *self.files],
            self.send_finished,
            lambda line: self.show_status(line, busy=True),
        )

    def send_finished(self, code):
        if code != 0:
            reason = self.errors[-1] if self.errors else "The device did not take it."
            self.state = "searching"
            self.show_status(f"Not sent: {reason}", busy=False)
            self.devices.setEnabled(True)
            self.selection_changed()
            # Quietly, so the list stays fresh and the reason stays on show.
            QTimer.singleShot(SEARCH_AGAIN_MS, self.search_again)
            return
        self.notify(f"Sent {describe(self.files)} to {self.recipient}")
        self.state = "done"
        self.accept()

    def fail(self, message):
        self.state = "failed"
        reason = f" {self.errors[-1]}" if self.errors else ""
        self.show_status(message + reason, busy=False)
        self.devices.setEnabled(False)
        self.selection_changed()

    # ------------------------------------------------------------- the rest

    def show_status(self, text, busy):
        self.status.setText(text)
        self.busy.setVisible(busy)

    def notify(self, text):
        try:
            subprocess.Popen(
                [NOTIFY_SEND, "-a", "AirDrop", "-i", "document-send", text],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass

    def done(self, result):
        """Every way the window closes: stop what runs, give the radio back."""
        self.state = "done"
        self.stop_process()
        if self.turned_on:
            self.turned_on = False
            QProcess.startDetached(OMDROP, ["off"])
        super().done(result)


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("omdrop-send")
    app.setDesktopFileName("omdrop-send")
    files = [f for f in app.arguments()[1:] if os.path.isfile(f)]
    if not files:
        QMessageBox.warning(None, "Send via AirDrop", "Choose one or more files to send.")
        return 2
    dialog = SendDialog(files)
    dialog.show()
    QTimer.singleShot(0, dialog.begin)
    return 0 if dialog.exec() == QDialog.DialogCode.Accepted else 1


if __name__ == "__main__":
    sys.exit(main())
