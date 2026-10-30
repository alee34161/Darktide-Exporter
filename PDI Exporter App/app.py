"""
Darktide stats uploader
=======================
Reads a pdi_*.json export written by the DT_Exporter Darktide mod and
uploads it to the stats database (Cloudflare D1, through the darktide-api Worker).

The mod writes exports to:
  <Darktide install>\\binaries\\dump\\pdi_YYYY-MM-DD_HH-MM-SS.json
when you leave a mission, or when /dt_export is used.

Run with:  python app.py
"""

import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext
import threading
import os
import re
import json
import fnmatch
import urllib.request
import ssl
import urllib.error
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).parent / ".env")
except ImportError:
    pass

# ── Constants ──────────────────────────────────────────────────────────────

API_URL      = os.environ.get("DT_API_URL", "").rstrip("/")
UPLOAD_TOKEN = os.environ.get("DT_UPLOAD_TOKEN", "")

# The permanent players, in the order the webapp lists them; anyone else is a random.
KNOWN_PLAYERS = ["Steven", "Injea", "Lee", "Blitter"]

TODO = "N/A"

# ── Lookup table ───────────────────────────────────────────────────────────

# Load lookup.json from this script's folder ({} if missing or invalid).
def load_lookup():
    path = Path(__file__).parent / "lookup.json"
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as e:
        print(f"Warning: could not parse lookup.json: {e}")
        return {}

_LOOKUP = load_lookup()

# lookup.json sections that identify talent categories.
_TALENT_CATEGORIES = ("blitz", "aura", "combat_ability", "keystones")

# Display name for a key: exact match, then wildcard pattern, else the raw key.
def lookup(section, key):
    if not key or key == TODO:
        return TODO
    section_data = _LOOKUP.get(section, {})
    val = section_data.get(key, "")
    if val:
        return val
    for pattern, display in section_data.items():
        if ("*" in pattern or "?" in pattern) and fnmatch.fnmatch(key, pattern):
            return display if display else key
    return key

# Talent keys listed under lookup.json "defaults" for a category.
def _default_keys_for(cat):
    raw = _LOOKUP.get("defaults", {}).get(cat)
    if not raw:
        return set()
    if isinstance(raw, str):
        return {raw}
    return set(raw)

# Pick blitz/aura/combat ability (non-default wins over default) and all keystones.
def resolve_talents(talents_selected):
    result = {cat: [] for cat in _TALENT_CATEGORIES}
    for talent_key in talents_selected:
        for cat in _TALENT_CATEGORIES:
            section = _LOOKUP.get(cat, {})
            if talent_key in section and talent_key != "_comment":
                display = section[talent_key]
                result[cat].append((display if display else talent_key, talent_key))
                break

    # Non-default match if any, else the default, else N/A.
    def pick_single(cat):
        matches = result[cat]
        if not matches:
            return TODO
        defaults = _default_keys_for(cat)
        non_default = [display for display, raw_key in matches if raw_key not in defaults]
        if non_default:
            return non_default[0]
        return matches[0][0]

    keystone_displays = [display for display, _raw_key in result["keystones"]]

    return {
        "blitz":          pick_single("blitz"),
        "aura":           pick_single("aura"),
        "combat_ability": pick_single("combat_ability"),
        "keystones":      "/".join(keystone_displays) if keystone_displays else TODO,
    }

# Darktide's binaries\dump folder, from the Steam install path if available.
def _find_dump_dir():
    try:
        import winreg
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1361210")
        install_path, _ = winreg.QueryValueEx(key, "InstallLocation")
        return Path(install_path) / "binaries" / "dump"
    except Exception:
        return Path(r"C:\Program Files (x86)\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\binaries\dump")

DEFAULT_JSON_DIR = _find_dump_dir()

DISPLAY_FIELDS = [
    ("date",                 "Date"),
    ("start_time",           "Start Time"),
    ("melee_elite_kills",    "Melee Elites"),
    ("ranged_elite_kills",   "Ranged Elites"),
    ("melee_special_kills",  "Melee Specials"),
    ("ranged_special_kills", "Ranged Specials"),
    ("ranged_trash_kills",   "Ranged Trash"),
    ("horde_trash_kills",    "Horde Trash"),
    ("boss_damage",          "Boss Damage"),
    ("elite_damage",         "Elite Damage"),
    ("horde_damage",         "Horde Damage"),
    ("specialist_damage",    "Specialist Damage"),
    ("revives_done",         "Revives"),
    ("needed_revives",       "Needed Revives"),
    ("ammo_used",            "Ammo Used"),
    ("blitz_uses",           "Blitz Uses"),
    ("combat_ability_uses",  "Combat Ability Uses"),
    ("damage_taken",         "Damage Taken"),
    ("class",                "Class"),
    ("melee_weapon",         "Melee Weapon"),
    ("ranged_weapon",        "Ranged Weapon"),
    ("blitz",                "Blitz"),
    ("aura",                 "Aura"),
    ("combat_ability",       "Combat Ability"),
    ("keystones",            "Keystone(s)"),
]

# ── JSON reader ────────────────────────────────────────────────────────────

# Strip DMF:dtf type suffixes: '123 (number)' -> 123, 'foo (string)' -> 'foo'.
def strip_dmf(value):
    if isinstance(value, str):
        for suffix in (" (number)", " (string)", " (boolean)"):
            if value.endswith(suffix):
                raw = value[: -len(suffix)]
                try:
                    return int(raw)
                except ValueError:
                    try:
                        return float(raw)
                    except ValueError:
                        return raw
    return value


# Read a pdi_*.json export. Returns (report, errors, run_info).
def read_export_json(path):
    errors = []
    try:
        with open(path, "rb") as f:
            raw = f.read().decode("utf-8")
        raw = re.sub(r'\r(?!\n)', r'\\r', raw)
        raw = raw.replace('\r\n', '\n')
        data = json.loads(raw)
    except FileNotFoundError:
        return None, [f"File not found: {path}\n\nMake sure the DT_Exporter mod is installed "
                      "and you have completed at least one mission."], None
    except (OSError, UnicodeDecodeError) as e:
        return None, [f"Could not read {path}: {e}\n\nSelect a pdi_*.json file, not a folder."], None
    except json.JSONDecodeError as e:
        return None, [f"Could not parse JSON file: {e}"], None

    data = next(iter(data.values())) if len(data) == 1 else data

    def get_int(d, key):
        return int(strip_dmf(d.get(key, 0)) or 0)

    def get_str(d, key):
        v = strip_dmf(d.get(key, ""))
        return str(v) if v else ""

    session_date = get_str(data, "session_date")
    session_time = get_str(data, "session_time")
    players_data = data.get("players", {})

    if not players_data:
        return None, ["No player data found in export file."], None

    equipment_data = data.get("equipment", {})

    run_info = _parse_havoc(data.get("havoc"), session_date, session_time)

    report = {}
    for in_game_name, stats in players_data.items():
        equip = equipment_data.get(in_game_name, {})

        raw_class  = str(strip_dmf(equip.get("class",        TODO)))
        raw_melee  = str(strip_dmf(equip.get("melee_weapon", TODO)))
        raw_ranged = str(strip_dmf(equip.get("ranged_weapon",TODO)))

        talents_selected = equip.get("talents_selected", {})
        talent_fields = resolve_talents(talents_selected)

        report[in_game_name] = {
            "date":                 session_date,
            "start_time":           session_time,
            "melee_elite_kills":    get_int(stats, "melee_elite_kills"),
            "ranged_elite_kills":   get_int(stats, "ranged_elite_kills"),
            "melee_special_kills":  get_int(stats, "melee_special_kills"),
            "ranged_special_kills": get_int(stats, "ranged_special_kills"),
            "ranged_trash_kills":   get_int(stats, "ranged_trash_kills"),
            "horde_trash_kills":    get_int(stats, "horde_trash_kills"),
            "boss_damage":          get_int(stats, "boss_damage"),
            "elite_damage":         get_int(stats, "elite_damage"),
            "horde_damage":         get_int(stats, "horde_damage"),
            "specialist_damage":    get_int(stats, "specialist_damage"),
            "revives_done":         get_int(stats, "revives_done"),
            "needed_revives":       get_int(stats, "needed_revives"),
            "ammo_used":            get_int(stats, "ammo_used"),
            "blitz_uses":           get_int(stats, "blitz_uses"),
            "combat_ability_uses":  get_int(stats, "combat_ability_uses"),
            "damage_taken":         get_int(stats, "damage_taken"),
            "class":          lookup("archetypes", raw_class),
            "melee_weapon":   lookup("weapons",    raw_melee),
            "ranged_weapon":  lookup("weapons",    raw_ranged),
            "blitz":          talent_fields["blitz"],
            "aura":           talent_fields["aura"],
            "combat_ability": talent_fields["combat_ability"],
            "keystones":      talent_fields["keystones"],
        }

    return report, errors, run_info


# Items of a Lua array, whether DMF:dtf wrote it as a list or a "1","2" object.
def _dtf_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        def _k(k):
            try:
                return int(k)
            except (TypeError, ValueError):
                return 0
        return [value[k] for k in sorted(value, key=_k)]
    return []


# The export's mission result: "win", "loss", "unfinished", or "unknown" for
# exports made before the mod recorded it.
def read_outcome(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        inner = next(iter(data.values())) if len(data) == 1 else data
        value = strip_dmf(inner.get("outcome"))
        return str(value) if value not in (None, "") else "unknown"
    except (OSError, ValueError, AttributeError, StopIteration):
        return "unknown"


# Havoc row for this run (rank and mutators), or None for non-Havoc missions.
def _parse_havoc(havoc, session_date, session_time):
    if not isinstance(havoc, dict):
        return None
    rank = strip_dmf(havoc.get("rank"))
    if rank in (None, ""):
        return None

    keys = [str(strip_dmf(c)) for c in _dtf_list(havoc.get("circumstances"))]
    return {
        "date":       session_date,
        "start_time": session_time,
        "rank":       rank,
        "mutators":   [lookup("havoc_mutators", k) for k in keys],
        "unknown":    [k for k in keys if lookup("havoc_mutators", k) == k],
    }


# certifi's certificate list when installed (Windows' own list can hold an
# expired root certificate), otherwise Python's default.
def _ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


SSL_CONTEXT = _ssl_context()


# ── Database upload ────────────────────────────────────────────────────────

STAT_KEYS = [
    "melee_elite_kills", "ranged_elite_kills", "melee_special_kills", "ranged_special_kills",
    "horde_trash_kills", "ranged_trash_kills", "boss_damage", "elite_damage", "horde_damage",
    "specialist_damage", "revives_done", "needed_revives", "ammo_used", "blitz_uses",
    "combat_ability_uses", "damage_taken",
]
LOADOUT_KEYS = ["class", "melee_weapon", "ranged_weapon", "blitz", "aura", "combat_ability", "keystones"]


# The run as the API expects it: known players by their real name, others by
# their mapped or in-game name.
def build_run_payload(report, player_map, run_info, outcome):
    first = next(iter(report.values()))
    players = []
    for position, (in_game, stats) in enumerate(report.items()):
        real_name = player_map.get(in_game, "").strip()
        known = next((k for k in KNOWN_PLAYERS if k.lower() == real_name.lower()), None)
        entry = {
            "player":       known or real_name or in_game,
            "in_game_name": in_game,
            "is_known":     known is not None,
            "sort_order":   KNOWN_PLAYERS.index(known) if known else 100 + position,
        }
        entry.update({k: stats.get(k, TODO) for k in LOADOUT_KEYS})
        entry.update({k: stats.get(k, 0) for k in STAT_KEYS})
        players.append(entry)
    return {
        "date":    first["date"],
        "time":    first["start_time"],
        "outcome": outcome if outcome in ("win", "loss", "unfinished") else None,
        "havoc":   {"rank": run_info["rank"], "mutators": run_info["mutators"]} if run_info else None,
        "players": players,
    }


# POST runs to the API; returns its JSON reply or raises with the error text.
def post_runs(body):
    if not API_URL or not UPLOAD_TOKEN:
        raise RuntimeError("DT_API_URL or DT_UPLOAD_TOKEN is not set. Add them to your .env file.")
    request = urllib.request.Request(
        f"{API_URL}/api/runs",
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type":  "application/json",
            "Authorization": f"Bearer {UPLOAD_TOKEN}",
            "User-Agent":    "darktide-uploader",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30, context=SSL_CONTEXT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"API returned {e.code}: {detail}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"Could not reach {API_URL}: {e.reason}") from None


# Upload one run with every player in it.
def upload_run(report, player_map, log_fn, run_info=None, outcome=None):
    payload = build_run_payload(report, player_map, run_info, outcome)
    result = post_runs(payload)
    for p in payload["players"]:
        tag = "" if p["is_known"] else " [random]"
        log_fn(f"  OK  {p['in_game_name']} -> {p['player']}{tag}")
    if run_info:
        log_fn(f"  OK  Havoc rank {run_info['rank']}")
    log_fn(f"  Saved run {', '.join(result.get('saved', []))}")


# ── GUI ────────────────────────────────────────────────────────────────────

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Darktide Uploader")
        self.resizable(False, False)
        self._report     = None
        self._run_info   = None
        self._outcome    = None
        self._json_path  = tk.StringVar(value=str(DEFAULT_JSON_DIR))
        self._build_ui()

    def _build_ui(self):
        PAD = 10

        map_frame = ttk.LabelFrame(
            self,
            text="Player Name Mapping  (in-game name  →  real name)"
        )
        map_frame.grid(row=0, column=0, padx=PAD, pady=(PAD, 4), sticky="ew")

        ttk.Label(map_frame, text="In-game name").grid(row=0, column=0, padx=8, pady=4)
        ttk.Label(map_frame, text="Real name").grid(row=0, column=1, padx=8, pady=4)

        self._player_vars = []
        for i in range(4):
            ig   = tk.StringVar()
            real = tk.StringVar()
            ttk.Entry(map_frame, textvariable=ig,   width=18).grid(row=i+1, column=0, padx=8, pady=3)
            ttk.Entry(map_frame, textvariable=real, width=18).grid(row=i+1, column=1, padx=8, pady=3)
            self._player_vars.append((ig, real))

        ttk.Label(
            map_frame,
            text=f"Known names: {', '.join(KNOWN_PLAYERS)}  |  Anyone else → Randoms",
            foreground="gray"
        ).grid(row=5, column=0, columnspan=2, padx=8, pady=(0, 6))

        path_frame = ttk.LabelFrame(self, text="Session Export File  (Darktide\\binaries\\dump\\pdi_*.json)")
        path_frame.grid(row=1, column=0, padx=PAD, pady=4, sticky="ew")

        ttk.Entry(path_frame, textvariable=self._json_path, width=55).grid(
            row=0, column=0, padx=8, pady=6)
        ttk.Button(path_frame, text="Browse",
                   command=self._browse_json).grid(row=0, column=1, padx=4)

        act_row = ttk.Frame(self)
        act_row.grid(row=2, column=0, padx=PAD, pady=4)

        self._btn_load = ttk.Button(act_row, text="Load Export File", command=self._on_load)
        self._btn_load.grid(row=0, column=0, padx=6)

        self._btn_upload = ttk.Button(
            act_row, text="Upload to Database",
            command=self._on_upload, state="disabled"
        )
        self._btn_upload.grid(row=0, column=1, padx=6)

        tbl_frame = ttk.LabelFrame(self, text="Extracted Data Preview")
        tbl_frame.grid(row=3, column=0, padx=PAD, pady=4, sticky="ew")

        self._tree = ttk.Treeview(
            tbl_frame,
            columns=("Field", "P1", "P2", "P3", "P4"),
            show="headings", height=20
        )
        self._tree.heading("Field", text="Field")
        self._tree.column("Field", width=210, anchor="w")
        for pid in ("P1", "P2", "P3", "P4"):
            self._tree.heading(pid, text=pid)
            self._tree.column(pid, width=110, anchor="center")

        vsb = ttk.Scrollbar(tbl_frame, orient="vertical", command=self._tree.yview)
        self._tree.configure(yscrollcommand=vsb.set)
        self._tree.grid(row=0, column=0, sticky="nsew")
        vsb.grid(row=0, column=1, sticky="ns")

        log_frame = ttk.LabelFrame(self, text="Log")
        log_frame.grid(row=4, column=0, padx=PAD, pady=(4, PAD), sticky="ew")

        self._log = scrolledtext.ScrolledText(
            log_frame, height=7, width=72,
            state="disabled", font=("Courier", 9)
        )
        self._log.grid(row=0, column=0, padx=6, pady=6)

    def _get_player_map(self):
        m = {}
        for ig_var, real_var in self._player_vars:
            ig   = ig_var.get().strip()
            real = real_var.get().strip()
            if ig and real:
                m[ig] = real
        return m

    def _log_msg(self, msg):
        def _w():
            self._log.config(state="normal")
            self._log.insert("end", msg + "\n")
            self._log.see("end")
            self._log.config(state="disabled")
        self.after(0, _w)

    def _browse_json(self):
        initial = str(DEFAULT_JSON_DIR) if DEFAULT_JSON_DIR.exists() else str(Path.home())
        path = filedialog.askopenfilename(
            title="Select a PDI export file",
            initialdir=initial,
            filetypes=[("JSON files", "*.json"), ("All", "*.*")]
        )
        if path:
            self._json_path.set(path)

    def _on_load(self):
        path = self._json_path.get().strip()
        if not path:
            messagebox.showwarning("No path", "Enter or browse to the export JSON file.")
            return

        self._log_msg(f"Loading {path} ...")
        report, errors, run_info = read_export_json(path)

        for e in errors:
            self._log_msg(f"ERROR: {e}")

        if not report:
            self._report = None
            self._run_info = None
            self._btn_upload.config(state="disabled")
            messagebox.showerror("Load failed", "\n".join(errors))
            return

        self._report = report
        self._run_info = run_info
        outcome = read_outcome(path)
        self._outcome = outcome
        self._log_msg(f"Result: {outcome.upper()}")
        self.title(f"Darktide Uploader - {os.path.basename(path)} - {outcome.upper()}")
        if run_info:
            self._log_msg(f"Havoc rank {run_info['rank']}: {', '.join(run_info['mutators']) or 'no mutators'}")
            for key in run_info["unknown"]:
                self._log_msg(f"  WARNING: mutator '{key}' is not in lookup.json; add it to \"havoc_mutators\".")
        self._populate_table(report)
        self._btn_upload.config(state="normal")
        self._log_msg(f"Loaded {len(report)} player(s): {', '.join(report.keys())}")
        self._autofill_player_names(report)

    # Fill in-game names from the file; real names stay with their in-game name.
    def _autofill_player_names(self, report):
        previous = {ig.get().strip(): real.get().strip() for ig, real in self._player_vars}
        names = list(report.keys())
        for i, (ig_var, real_var) in enumerate(self._player_vars):
            name = names[i] if i < len(names) else ""
            ig_var.set(name)
            real_var.set(previous.get(name, "") if name else "")
        self._log_msg(f"  Auto-filled player names: {', '.join(names)}")

    def _populate_table(self, report):
        for item in self._tree.get_children():
            self._tree.delete(item)
        for pid in ("P1","P2","P3","P4"):
            self._tree.heading(pid, text=pid)

        if not report:
            return

        players = list(report.keys())
        pid_map = {pid: players[i]
                   for i, pid in enumerate(("P1","P2","P3","P4"))
                   if i < len(players)}
        for pid, name in pid_map.items():
            self._tree.heading(pid, text=name)

        for key, label in DISPLAY_FIELDS:
            vals = [label]
            for pid in ("P1","P2","P3","P4"):
                p = pid_map.get(pid)
                if p:
                    v = report[p].get(key, "")
                    vals.append(f"{v:,}" if isinstance(v, int) else str(v or ""))
                else:
                    vals.append("")
            self._tree.insert("", "end", values=vals)

    def _on_upload(self):
        if not self._report:
            messagebox.showwarning("No data", "Load the export file first.")
            return

        player_map = self._get_player_map()
        if not player_map:
            messagebox.showwarning("No mapping",
                                   "Fill in at least one player name mapping.")
            return

        unknown = self._run_info["unknown"] if self._run_info else []
        warning = (f"\n\nUnrecognised mutators: {', '.join(unknown)}.\n"
                   "Add them to lookup.json and reload the file first, or fix them later "
                   "with fix_mutators.py.") if unknown else ""
        if not messagebox.askyesno(
            "Confirm Upload",
            "Upload this run to the database?\nUploading the same run again replaces it." + warning
        ):
            return

        self._btn_upload.config(state="disabled")
        self._btn_load.config(state="disabled")
        self._log_msg("Uploading...")

        def run():
            try:
                upload_run(self._report, player_map, self._log_msg, self._run_info, self._outcome)
                self.after(0, self._on_upload_done)
            except Exception as e:
                self._log_msg(f"Upload error: {e}")
                self.after(0, lambda: (
                    self._btn_upload.config(state="normal"),
                    self._btn_load.config(state="normal"),
                ))

        threading.Thread(target=run, daemon=True).start()

    def _on_upload_done(self):
        self._btn_load.config(state="normal")
        self._btn_upload.config(state="normal")
        self._log_msg("Upload complete.")
        messagebox.showinfo("Done", "Data uploaded successfully.")


if __name__ == "__main__":
    app = App()
    app.mainloop()
