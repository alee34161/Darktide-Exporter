"""
Fix Havoc mutator names already in the database
===============================================
Finds uploaded runs whose mutators are still raw game keys (e.g. "darkness_01")
and replaces them with their names from lookup.json, then re-uploads those runs.

Typical use: add the missing key to "havoc_mutators" in lookup.json, then run
  python fix_mutators.py
You can also rename directly, without editing lookup.json:
  python fix_mutators.py "darkness_01=Power Supply Interruption"

Shows every change and asks before uploading. Uses DT_API_URL and
DT_UPLOAD_TOKEN from the same .env as app.py.
"""

import fnmatch
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).parent / ".env")
except ImportError:
    pass

API_URL = os.environ.get("DT_API_URL", "").rstrip("/")
UPLOAD_TOKEN = os.environ.get("DT_UPLOAD_TOKEN", "")
LOADOUT_KEYS = ["class", "melee_weapon", "ranged_weapon", "blitz", "aura", "combat_ability", "keystones"]
BATCH_SIZE = 25


# certifi's certificate list when installed (Windows' own list can hold an
# expired root certificate), otherwise Python's default.
def _ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


SSL_CONTEXT = _ssl_context()


# lookup.json's "havoc_mutators" section ({} if the file is missing).
def load_mutator_names():
    try:
        with open(Path(__file__).parent / "lookup.json", "r", encoding="utf-8") as f:
            return json.load(f).get("havoc_mutators", {})
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


# Name for a stored mutator: a command-line rename, an exact lookup.json key,
# or a wildcard pattern; None when it needs no change.
def corrected_name(stored, names, overrides):
    if stored in overrides:
        return overrides[stored]
    if names.get(stored):
        return names[stored]
    for pattern, display in names.items():
        if display and ("*" in pattern or "?" in pattern) and fnmatch.fnmatch(stored, pattern):
            return display
    return None


def api(method, path, body=None):
    headers = {"User-Agent": "darktide-fix-mutators"}
    data = None
    if body is not None:
        headers.update({"Content-Type": "application/json", "Authorization": f"Bearer {UPLOAD_TOKEN}"})
        data = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(f"{API_URL}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60, context=SSL_CONTEXT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"API returned {e.code}: {e.read().decode('utf-8', 'replace')}") from None


# The run in upload format, with corrected mutators and players in their current order.
def as_upload(run, mutators):
    date, time = run["key"].split("T")
    year, month, day = date.split("-")
    players = []
    for order, p in enumerate(run["players"]):
        entry = {
            "player": p["player"], "in_game_name": p.get("in_game_name"),
            "is_known": p.get("is_known", False), "sort_order": order,
        }
        entry.update(dict(zip(LOADOUT_KEYS, p["loadout"])))
        entry.update(p["stats"])
        players.append(entry)
    return {
        "date": f"{month}/{day}/{year}", "time": time, "outcome": run.get("outcome"),
        "havoc": {"rank": run["havoc"]["rank"], "mutators": mutators}, "players": players,
    }


def main():
    if not API_URL or not UPLOAD_TOKEN:
        sys.exit("Set DT_API_URL and DT_UPLOAD_TOKEN in .env")
    overrides = dict(arg.split("=", 1) for arg in sys.argv[1:] if "=" in arg)
    names = load_mutator_names()

    changed = []
    for run in api("GET", "/api/runs")["runs"]:
        if not run.get("havoc"):
            continue
        old = run["havoc"]["mutators"]
        new = [corrected_name(m, names, overrides) or m for m in old]
        if new != old:
            changed.append(as_upload(run, new))
            fixes = ", ".join(f"{a} -> {b}" for a, b in zip(old, new) if a != b)
            print(f"{run['key']}  Havoc {run['havoc']['rank']}: {fixes}")

    if not changed:
        print("Every stored mutator already has a name. Nothing to fix.")
        return
    if input(f"\nRe-upload {len(changed)} run(s) with these names? [y/N] ").strip().lower() != "y":
        print("Nothing changed.")
        return
    for start in range(0, len(changed), BATCH_SIZE):
        api("POST", "/api/runs", {"runs": changed[start:start + BATCH_SIZE]})
    print(f"Updated {len(changed)} run(s).")


if __name__ == "__main__":
    main()
