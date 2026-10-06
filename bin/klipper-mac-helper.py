#!/usr/bin/env python3
"""Small companion service for Klipper on macOS.

1. Keeps the Mac awake (caffeinate) only while a print is running or paused.
2. macOS has no inotify, so Moonraker cannot see G-code files that are copied
   into the gcodes folder by hand (or saved there by a slicer). This asks
   Moonraker to scan new files, so Mainsail shows time, filament and thumbnails.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("MOONRAKER_URL", "http://127.0.0.1:7125")
GCODES = os.path.expanduser(os.environ.get("GCODES_DIR", "~/printer_data/gcodes"))
POLL_SECONDS = 15

caffeinate = None
seen = {}


def call(path, method="GET"):
    req = urllib.request.Request(API + path, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["result"]


def scan_new_files():
    for base, _, files in os.walk(GCODES):
        for name in files:
            if not name.lower().endswith((".gcode", ".g", ".gco")):
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, GCODES)
            mtime = os.path.getmtime(full)
            if seen.get(rel) == mtime or time.time() - mtime < 3:
                continue  # already handled, or the slicer is still writing it
            q = urllib.parse.quote(rel)
            try:
                call(f"/server/files/metadata?filename={q}")
            except urllib.error.HTTPError:
                call(f"/server/files/metascan?filename={q}", "POST")
            seen[rel] = mtime


while True:
    try:
        state = call("/printer/objects/query?print_stats=state")["status"]["print_stats"]["state"]
    except Exception:
        state = None  # Moonraker or Klipper not ready yet
    busy = state in ("printing", "paused")
    if busy and (caffeinate is None or caffeinate.poll() is not None):
        caffeinate = subprocess.Popen(["caffeinate", "-ims"])
        print("print running: keeping the Mac awake", file=sys.stderr, flush=True)
    elif not busy and caffeinate is not None and state is not None:
        caffeinate.terminate()
        caffeinate = None
        print("printer idle: sleep allowed again", file=sys.stderr, flush=True)
    try:
        scan_new_files()
    except Exception:
        pass
    time.sleep(POLL_SECONDS)
