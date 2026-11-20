"""
FlySolo tray widget (Windows).

  * Tray icon: green = all quiet, red = something new happened, gray = checking
  * Click the icon for a window with the guard log and current status
  * Re-checks every CHECK_EVERY_MIN minutes; pops a notification when the guard
    log gets new lines or a Copilot package is installed for your user
  * "Run guard now" and "Repair" ask for admin rights (UAC) only when clicked;
    the widget itself always runs as a normal user

Run from source:  py -m pip install pystray pillow  then  pyw guard_widget.py
"""
import ctypes
import datetime
import json
import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import messagebox, ttk
from tkinter.scrolledtext import ScrolledText

import pystray
from PIL import Image, ImageDraw

VERSION = "0.1.0"

# ------------------------------------------------------------------ paths & settings
ROOT = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "FlySolo")
LOG_FILE = os.path.join(ROOT, "guard.log")
STATUS_FILE = os.path.join(ROOT, "status.json")
CONFIG_FILE = os.path.join(ROOT, "config.json")
GUARD_PS1 = os.path.join(ROOT, "guard.ps1")
INSTALL_PS1 = os.path.join(ROOT, "install.ps1")

CHECK_EVERY_MIN = 15
TAIL_LINES = 300
DEFAULT_PATTERNS = ["*Microsoft.Copilot*", "*Microsoft.Windows.Ai.Copilot*"]

STATE_DIR = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "FlySolo")
STATE_FILE = os.path.join(STATE_DIR, "widget-state.json")
CREATE_NO_WINDOW = 0x08000000


# ------------------------------------------------------------------ helpers
def ps(command, timeout=60):
    """Run a PowerShell command without flashing a console window."""
    try:
        r = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
            capture_output=True, text=True, timeout=timeout, creationflags=CREATE_NO_WINDOW,
        )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def run_elevated(script, args=""):
    """Run a .ps1 as admin via UAC. Returns True if the user approved."""
    params = f'-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{script}" {args}'.strip()
    rc = ctypes.windll.shell32.ShellExecuteW(None, "runas", "powershell.exe", params, None, 0)
    return rc > 32  # <= 32 is an error; 5 means the UAC prompt was declined


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return None
    except OSError as e:
        return [f"(can't read log: {e})"]


def save_state(state):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(state, f)
    except OSError:
        pass


def new_lines_since(lines, last_seen):
    """Lines after the last line we saw. If it's gone (log trimmed), treat all as new."""
    if not lines:
        return []
    if last_seen is None:
        return lines
    for i in range(len(lines) - 1, -1, -1):
        if lines[i] == last_seen:
            return lines[i + 1:]
    return lines


def ps_quote(s):
    return "'" + s.replace("'", "''") + "'"


def make_icon(color):
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((4, 4, 60, 60), fill=color, outline=(30, 30, 30, 255), width=3)
    d.rectangle((26, 16, 38, 48), fill=(255, 255, 255, 230))
    d.rectangle((18, 26, 46, 36), fill=(255, 255, 255, 230))
    return img


ICONS = {
    "ok": make_icon((40, 160, 70, 255)),
    "alert": make_icon((200, 40, 40, 255)),
    "unknown": make_icon((130, 130, 130, 255)),
}


# ------------------------------------------------------------------ checks (worker thread)
def run_checks():
    cfg = read_json(CONFIG_FILE, {}) or {}
    patterns = cfg.get("patterns") or DEFAULT_PATTERNS
    pats = ",".join(ps_quote(p) for p in patterns)

    status = {
        "time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
        "installed": bool(cfg),
        "version": cfg.get("version", "?"),
        "guard": read_json(STATUS_FILE),
        "log": read_lines(LOG_FILE),
    }

    # Copilot packages for *this* user (checking all users needs admin)
    code, out, _ = ps(
        f"$p=@({pats}); Get-AppxPackage | Where-Object {{ $n=$_.Name; @($p | Where-Object {{ $n -like $_ }}).Count }}"
        " | ForEach-Object { $_.Name }"
    )
    status["packages"] = [x for x in out.splitlines() if x.strip()] if code == 0 else None
    return status


# ------------------------------------------------------------------ app
class GuardWidget:
    def __init__(self):
        self.q = queue.Queue()
        self.state = read_json(STATE_FILE, {}) or {}
        self.status = None
        self.unread = False
        self.checking = threading.Lock()
        self.timer = None

        self.root = tk.Tk()
        self.root.title(f"FlySolo {VERSION}")
        self.root.geometry("780x440")
        self.root.protocol("WM_DELETE_WINDOW", self.root.withdraw)
        self.root.withdraw()

        top = ttk.Frame(self.root, padding=6)
        top.pack(fill="x")
        self.status_var = tk.StringVar(value="Waiting for first check...")
        ttk.Label(top, textvariable=self.status_var, justify="left").pack(side="left", anchor="w")

        btns = ttk.Frame(top)
        btns.pack(side="right", anchor="n")
        ttk.Button(btns, text="Check now", command=self.check_now).pack(fill="x", pady=1)
        ttk.Button(btns, text="Run guard now (admin)", command=self.run_guard).pack(fill="x", pady=1)
        ttk.Button(btns, text="Repair (admin)", command=self.repair).pack(fill="x", pady=1)
        ttk.Button(btns, text="Open folder", command=self.open_folder).pack(fill="x", pady=1)

        self.text = ScrolledText(self.root, wrap="none", font=("Consolas", 9), state="disabled")
        self.text.pack(fill="both", expand=True, padx=6, pady=(0, 6))

        menu = pystray.Menu(
            pystray.MenuItem("Show log", lambda: self.q.put(("show",)), default=True),
            pystray.MenuItem("Check now", lambda: self.q.put(("check",))),
            pystray.MenuItem("Quit", lambda: self.q.put(("quit",))),
        )
        self.icon = pystray.Icon("FlySolo", ICONS["unknown"], "FlySolo: starting", menu)
        self.icon.run_detached()

        self.root.after(200, self.pump)
        self.check_now()

    # ---- everything that touches Tk runs here, on the main thread
    def pump(self):
        try:
            while True:
                msg = self.q.get_nowait()
                if msg[0] == "show":
                    self.show()
                elif msg[0] == "check":
                    self.check_now()
                elif msg[0] == "status":
                    self.apply_status(msg[1])
                elif msg[0] == "quit":
                    self.icon.stop()
                    self.root.destroy()
                    return
        except queue.Empty:
            pass
        self.root.after(200, self.pump)

    def schedule_next(self, minutes=CHECK_EVERY_MIN):
        if self.timer is not None:
            self.root.after_cancel(self.timer)
        self.timer = self.root.after(int(minutes * 60 * 1000), self.check_now)

    def check_now(self):
        if not self.checking.acquire(blocking=False):
            return
        self.icon.icon = ICONS["unknown"]

        def work():
            try:
                self.q.put(("status", run_checks()))
            finally:
                self.checking.release()

        threading.Thread(target=work, daemon=True).start()

    def apply_status(self, s):
        self.status = s
        alerts = []
        if s["packages"]:
            alerts.append("Copilot is installed for you: " + ", ".join(s["packages"]))

        lines = s["log"]
        last_seen = self.state.get("last_seen")
        if lines:
            fresh = new_lines_since(lines, last_seen)
            if fresh and "last_seen" in self.state:   # first run sets a baseline, no alert
                alerts.append(f"Guard log: {len(fresh)} new line(s), latest: {fresh[-1][:120]}")
            self.state["last_seen"] = lines[-1]
        elif "last_seen" not in self.state:
            self.state["last_seen"] = None
        save_state(self.state)

        if alerts:
            self.unread = True
            try:
                self.icon.notify("\n".join(alerts)[:250], "FlySolo")
            except Exception:  # noqa: BLE001
                pass

        self.refresh_window()
        self.update_icon()
        self.schedule_next()

    def update_icon(self):
        s = self.status
        if s is None:
            self.icon.icon, tip = ICONS["unknown"], "FlySolo: checking"
        elif self.unread or s["packages"] or not s["installed"]:
            self.icon.icon, tip = ICONS["alert"], "FlySolo: needs a look - click to view"
        else:
            self.icon.icon, tip = ICONS["ok"], f"FlySolo: all quiet ({s['time']})"
        self.icon.title = tip[:127]

    def refresh_window(self):
        s = self.status
        if not s:
            return
        if s["packages"] is None:
            pkgs = "couldn't check"
        elif s["packages"]:
            pkgs = "INSTALLED: " + ", ".join(s["packages"])
        else:
            pkgs = "none for your user"

        g = s["guard"]
        if not s["installed"]:
            guard = "NOT INSTALLED - run install.ps1"
        elif g:
            guard = f"last ran {g.get('lastRun', '?').replace('T', ' ')}, removed {g.get('removed', 0)}, failed {g.get('failed', 0)}"
        else:
            guard = "hasn't reported yet"

        self.status_var.set(
            f"Last check: {s['time']}   (every {CHECK_EVERY_MIN} min)\n"
            f"Copilot packages: {pkgs}\n"
            f"Guard: {guard}"
        )
        t = self.text
        t.configure(state="normal")
        t.delete("1.0", "end")
        if s["log"] is None:
            t.insert("end", "(no log yet - the guard hasn't had to remove anything)\n")
        elif not s["log"]:
            t.insert("end", "(log is empty)\n")
        else:
            t.insert("end", "\n".join(s["log"][-TAIL_LINES:]) + "\n")
        t.see("end")
        t.configure(state="disabled")

    # ---- buttons
    def run_guard(self):
        if not os.path.exists(GUARD_PS1):
            messagebox.showerror("FlySolo", f"{GUARD_PS1} not found. Is FlySolo installed?")
            return
        if run_elevated(GUARD_PS1):
            self.status_var.set("Running guard... will re-check in 20 seconds.")
            self.root.after(20000, self.check_now)

    def repair(self):
        if not os.path.exists(INSTALL_PS1):
            messagebox.showerror("FlySolo", f"{INSTALL_PS1} not found. Is FlySolo installed?")
            return
        if run_elevated(INSTALL_PS1, "-Repair"):
            self.status_var.set("Repairing... will re-check in 45 seconds.")
            self.root.after(45000, self.check_now)

    def open_folder(self):
        if os.path.isdir(ROOT):
            os.startfile(ROOT)

    def show(self):
        self.unread = False
        self.update_icon()
        self.refresh_window()
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()

    def run(self):
        self.root.mainloop()


def main():
    # one widget per user session
    ctypes.windll.kernel32.CreateMutexW(None, False, "Local\\FlySoloWidget")
    if ctypes.windll.kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        sys.exit(0)
    GuardWidget().run()


if __name__ == "__main__":
    main()
