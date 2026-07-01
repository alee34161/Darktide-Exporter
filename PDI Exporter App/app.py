"""
Darktide Power_DI -> Google Sheets Uploader
============================================
Reads pdi_export.json written by the PDI_Exporter Darktide mod
and uploads stats to Google Sheets.

The JSON file is automatically written to:
  %appdata%\\Fatshark\\Darktide\\pdi_export.json
after each mission (when the PDI_Exporter mod is installed).

Run with:  python app_json.py
"""

import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext
import threading
import os
import re
import json
from pathlib import Path
from datetime import datetime

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).parent / ".env")
except ImportError:
    pass

# ── Constants ──────────────────────────────────────────────────────────────

SPREADSHEET_ID = os.environ.get("GOOGLE_SHEET_ID", "")

PLAYER_TABS = {
    "Steven":  "Steven Data",
    "Injea":   "Injea Data",
    "Lee":     "Lee Data",
    "Blitter": "Blitter Data",
}

# Players whose names are NOT in PLAYER_TABS get routed here.
# Multiple randoms from the same session are all stored in this single tab,
# each as their own stats+equip row pair, with their name appended at the end
# of the stats row so the Apps Script can identify them per run.
RANDOMS_TAB = os.environ.get("RANDOMS_TAB_NAME", "Randoms")

TODO = "TODO"

# ── Lookup table ───────────────────────────────────────────────────────────

def load_lookup():
    """Load lookup.json from same directory as this script. Returns dict."""
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

# Talent categories resolved by which section a key lives in
_TALENT_CATEGORIES = ("blitz", "aura", "combat_ability", "keystones")

def lookup(section, key):
    """Return display name for key in section, or key itself as fallback."""
    if not key or key == TODO:
        return TODO
    val = _LOOKUP.get(section, {}).get(key, "")
    return val if val else key

def _default_keys_for(cat):
    """
    Return the set of talent keys that count as "default" for a category,
    per lookup.json's top-level "defaults" section, e.g.:
        "defaults": {
            "blitz": "default_blitz_key",
            "aura": ["default_aura_key_a", "default_aura_key_b"],
            "combat_ability": "default_combat_ability_key"
        }
    A category can map to a single key (string) or multiple (list).
    """
    raw = _LOOKUP.get("defaults", {}).get(cat)
    if not raw:
        return set()
    if isinstance(raw, str):
        return {raw}
    return set(raw)

def resolve_talents(talents_selected):
    """
    Given a dict of {talent_key: 1} from the exporter, search lookup.json
    sections to find blitz, aura, combat_ability, and keystone(s).

    A player can have multiple talents in the same category (e.g. an aura
    granted by a curio in addition to their selected aura). Only ONE should
    be reported: the non-default one if present, otherwise the default.
    Keystones still combine all matches (a player can run more than one).

    Returns a dict with those four keys filled in (display name or raw key
    as fallback, TODO if none found).
    """
    # Each entry is (display_name, raw_key) so we can tell defaults apart
    result = {cat: [] for cat in _TALENT_CATEGORIES}
    for talent_key in talents_selected:
        for cat in _TALENT_CATEGORIES:
            section = _LOOKUP.get(cat, {})
            if talent_key in section and talent_key != "_comment":
                display = section[talent_key]
                result[cat].append((display if display else talent_key, talent_key))
                break  # a key only belongs to one category

    def pick_single(cat):
        """Prefer a non-default match; fall back to a default; else TODO."""
        matches = result[cat]
        if not matches:
            return TODO
        defaults = _default_keys_for(cat)
        non_default = [display for display, raw_key in matches if raw_key not in defaults]
        if non_default:
            return non_default[0]
        # Nothing but defaults matched (or no defaults configured at all)
        return matches[0][0]

    keystone_displays = [display for display, _raw_key in result["keystones"]]

    return {
        "blitz":          pick_single("blitz"),
        "aura":           pick_single("aura"),
        "combat_ability": pick_single("combat_ability"),
        "keystones":      "/".join(keystone_displays) if keystone_displays else TODO,
    }

# PDI_Exporter writes via DMF:dtf to DARKTIDE\binaries\dump\
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
    ("melee_elite_kills",    "Melee Elite Kills"),
    ("ranged_elite_kills",   "Ranged Elite Kills"),
    ("melee_special_kills",  "Melee Special Kills"),
    ("ranged_special_kills", "Ranged Special Kills"),
    ("ranged_trash_kills",   "Ranged Trash Kills"),
    ("horde_trash_kills",    "Horde Trash Kills"),
    ("boss_damage",          "Boss Damage"),
    ("elite_damage",         "Elite Damage"),
    ("horde_damage",         "Horde Damage"),
    ("specialist_damage",    "Specialist Damage"),
    ("revives_done",         "Revives Done"),
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

def strip_dmf(value):
    """Strip DMF:dtf type suffixes: '123 (number)' -> 123, 'foo (string)' -> 'foo'."""
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


def read_export_json(path):
    """
    Read a pdi_*.json file written by PDI_Exporter via DMF:dtf.
    DMF:dtf wraps the table in a top-level key (the filename) and appends
    type suffixes like ' (number)' to all values.
    Returns (report, errors) where report is {in_game_name: {field: value}}.
    """
    errors = []
    try:
        with open(path, "rb") as f:
            raw = f.read().decode("utf-8")
        # DMF:dtf embeds literal \r inside string values (from dev_description
        # fields in weapon data). Fix bare \r before JSON parsing.
        raw = re.sub(r'\r(?!\n)', r'\\r', raw)
        raw = raw.replace('\r\n', '\n')
        data = json.loads(raw)
    except FileNotFoundError:
        return None, [f"File not found: {path}\n\nMake sure the PDI_Exporter mod is installed "
                      "and you have completed at least one mission."]
    except json.JSONDecodeError as e:
        return None, [f"Could not parse JSON file: {e}"]

    # DMF:dtf wraps everything in a top-level key matching the filename
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
        return None, ["No player data found in export file."]

    equipment_data = data.get("equipment", {})

    report = {}
    for in_game_name, stats in players_data.items():
        equip = equipment_data.get(in_game_name, {})

        raw_class  = str(strip_dmf(equip.get("class",        TODO)))
        raw_melee  = str(strip_dmf(equip.get("melee_weapon", TODO)))
        raw_ranged = str(strip_dmf(equip.get("ranged_weapon",TODO)))

        # Resolve blitz/aura/combat_ability/keystones from the full talent list
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
            # Equipment — class/weapons via lookup.json, talents resolved by section
            "class":          lookup("archetypes", raw_class),
            "melee_weapon":   lookup("weapons",    raw_melee),
            "ranged_weapon":  lookup("weapons",    raw_ranged),
            "blitz":          talent_fields["blitz"],
            "aura":           talent_fields["aura"],
            "combat_ability": talent_fields["combat_ability"],
            "keystones":      talent_fields["keystones"],
        }

    return report, errors


# ── Google Sheets ──────────────────────────────────────────────────────────

def get_sheets_service():
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    email   = os.environ.get("GOOGLE_SERVICE_ACCOUNT_EMAIL", "").strip()
    raw_key = os.environ.get("GOOGLE_PRIVATE_KEY", "").strip()
    if (raw_key.startswith('"') and raw_key.endswith('"')) or \
       (raw_key.startswith("'") and raw_key.endswith("'")):
        raw_key = raw_key[1:-1]
    key = raw_key.replace("\\n", "\n")

    if not email or not key:
        raise RuntimeError("Missing GOOGLE_SERVICE_ACCOUNT_EMAIL or GOOGLE_PRIVATE_KEY in .env")

    creds = service_account.Credentials.from_service_account_info(
        {
            "type":           "service_account",
            "client_email":   email,
            "private_key":    key,
            "private_key_id": "",
            "client_id":      "",
            "auth_uri":       "https://accounts.google.com/o/oauth2/auth",
            "token_uri":      "https://oauth2.googleapis.com/token",
        },
        scopes=["https://www.googleapis.com/auth/spreadsheets"],
    )
    return build("sheets", "v4", credentials=creds, cache_discovery=False)


def get_next_stats_row(service, tab_name):
    result = service.spreadsheets().values().get(
        spreadsheetId=SPREADSHEET_ID,
        range=f"'{tab_name}'!A:A"
    ).execute()
    last = len(result.get("values", []))
    if last < 2:
        return 2
    next_row = last + 1
    return next_row + 1 if next_row % 2 != 0 else next_row


def _build_equip_row(stats):
    return [
        stats.get("class",          TODO),
        stats.get("melee_weapon",   TODO),
        stats.get("ranged_weapon",  TODO),
        stats.get("blitz",          TODO),
        stats.get("aura",           TODO),
        stats.get("combat_ability", TODO),
        stats.get("keystones",      TODO),
    ]


def _build_stats_row(stats):
    return [
        stats["date"],               stats["start_time"],
        stats["melee_elite_kills"],  stats["ranged_elite_kills"],
        stats["melee_special_kills"],stats["ranged_special_kills"],
        stats["ranged_trash_kills"], stats["horde_trash_kills"],
        stats["boss_damage"],        stats["elite_damage"],
        stats["horde_damage"],       stats["specialist_damage"],
        stats["revives_done"],       stats["needed_revives"],
        stats["ammo_used"],          stats["blitz_uses"],
        stats["combat_ability_uses"],stats["damage_taken"],
    ]


def _ensure_randoms_tab_exists(service):
    """
    Create the Randoms sheet tab in the spreadsheet if it doesn't exist yet.
    Returns True if the tab was just created (so caller knows headers are needed).
    """
    meta = service.spreadsheets().get(spreadsheetId=SPREADSHEET_ID).execute()
    existing = {s["properties"]["title"] for s in meta.get("sheets", [])}
    if RANDOMS_TAB in existing:
        return False
    service.spreadsheets().batchUpdate(
        spreadsheetId=SPREADSHEET_ID,
        body={"requests": [{"addSheet": {"properties": {"title": RANDOMS_TAB}}}]},
    ).execute()
    return True  # newly created — headers not yet written


def ensure_randoms_tab_headers(service):
    """
    Create the Randoms tab if missing, then write header rows if the tab is empty.
    Row 1: stats headers (Date, Time, kills, damage … Player Name at the end)
    Row 2: equip headers (Class, Melee Weapon, …)
    """
    just_created = _ensure_randoms_tab_exists(service)
    if not just_created:
        # Tab already existed — check whether headers are already there
        result = service.spreadsheets().values().get(
            spreadsheetId=SPREADSHEET_ID,
            range=f"'{RANDOMS_TAB}'!A1",
        ).execute()
        if result.get("values"):
            return  # headers already present

    stats_header = [
        "Date", "Time",
        "Melee Elite Kills", "Ranged Elite Kills",
        "Melee Special Kills", "Ranged Special Kills",
        "Ranged Trash Kills", "Horde Trash Kills",
        "Boss Damage", "Elite Damage",
        "Horde Damage", "Specialist Damage",
        "Revives Done", "Needed Revives",
        "Ammo Used", "Blitz Uses",
        "Combat Ability Uses", "Damage Taken",
        "Player Name",
    ]
    equip_header = [
        "Class", "Melee Weapon", "Ranged Weapon",
        "Blitz", "Aura", "Combat Ability", "Keystone(s)",
    ]
    service.spreadsheets().values().batchUpdate(
        spreadsheetId=SPREADSHEET_ID,
        body={
            "valueInputOption": "USER_ENTERED",
            "data": [
                {"range": f"'{RANDOMS_TAB}'!A1", "values": [stats_header]},
                {"range": f"'{RANDOMS_TAB}'!A2", "values": [equip_header]},
            ],
        },
    ).execute()


def upload_to_sheets(report, player_map, log_fn):
    """
    Upload report to Sheets.  player_map = {in_game_name: real_name}.

    Routing rules:
      • real_name is in PLAYER_TABS  → upload to that player's own tab (existing behaviour)
      • real_name is NOT in PLAYER_TABS (unknown / empty mapping) → upload to RANDOMS_TAB
        Multiple randoms from the same session each get their own row-pair;
        the player's display name is appended as the last column of the stats row
        so the Apps Script can match them to a run by date+time+name.
    """
    if not SPREADSHEET_ID:
        raise RuntimeError(
            "GOOGLE_SHEET_ID is not set. Add it to your .env file."
        )

    service = get_sheets_service()
    randoms_headers_ensured = False

    for in_game, stats in report.items():
        real_name  = player_map.get(in_game, "").strip()
        tab        = PLAYER_TABS.get(real_name) if real_name else None

        if tab:
            # ── Named player ────────────────────────────────────────────────
            row = get_next_stats_row(service, tab)
            service.spreadsheets().values().batchUpdate(
                spreadsheetId=SPREADSHEET_ID,
                body={
                    "valueInputOption": "USER_ENTERED",
                    "data": [
                        {"range": f"'{tab}'!A{row}",     "values": [_build_stats_row(stats)]},
                        {"range": f"'{tab}'!A{row + 1}", "values": [_build_equip_row(stats)]},
                    ],
                },
            ).execute()
            log_fn(f"  OK  {in_game} ({real_name}) -> '{tab}' rows {row}-{row+1}")

        else:
            # ── Random player ────────────────────────────────────────────────
            # Use the real_name if the user typed something that just isn't a
            # known player; otherwise fall back to the in-game name.
            display_name = real_name if real_name else in_game

            if not randoms_headers_ensured:
                ensure_randoms_tab_headers(service)
                randoms_headers_ensured = True

            row = get_next_stats_row(service, RANDOMS_TAB)

            # Stats row for Randoms has player display name appended at the end
            randoms_stats_row = _build_stats_row(stats) + [display_name]

            service.spreadsheets().values().batchUpdate(
                spreadsheetId=SPREADSHEET_ID,
                body={
                    "valueInputOption": "USER_ENTERED",
                    "data": [
                        {"range": f"'{RANDOMS_TAB}'!A{row}",     "values": [randoms_stats_row]},
                        {"range": f"'{RANDOMS_TAB}'!A{row + 1}", "values": [_build_equip_row(stats)]},
                    ],
                },
            ).execute()
            log_fn(f"  OK  {in_game} ({display_name!r}) -> '{RANDOMS_TAB}' rows {row}-{row+1} [random]")


# ── GUI ────────────────────────────────────────────────────────────────────

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Darktide PDI -> Google Sheets")
        self.resizable(False, False)
        self._report     = None
        self._json_path  = tk.StringVar(value=str(DEFAULT_JSON_DIR))
        self._build_ui()

    def _build_ui(self):
        PAD = 10

        # ── Player mapping ──
        map_frame = ttk.LabelFrame(
            self,
            text="Player Name Mapping  (in-game name  →  real name for Sheet tab)"
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
            text="Known names: Steven, Injea, Lee, Blitter  |  Anyone else → Randoms tab",
            foreground="gray"
        ).grid(row=5, column=0, columnspan=2, padx=8, pady=(0, 6))

        # ── JSON file path ──
        path_frame = ttk.LabelFrame(self, text="Session Export File  (%appdata%/Fatshark/Darktide/pdi_exports/)")
        path_frame.grid(row=1, column=0, padx=PAD, pady=4, sticky="ew")

        ttk.Entry(path_frame, textvariable=self._json_path, width=55).grid(
            row=0, column=0, padx=8, pady=6)
        ttk.Button(path_frame, text="Browse",
                   command=self._browse_json).grid(row=0, column=1, padx=4)

        # ── Action buttons ──
        act_row = ttk.Frame(self)
        act_row.grid(row=2, column=0, padx=PAD, pady=4)

        self._btn_load = ttk.Button(act_row, text="Load Export File", command=self._on_load)
        self._btn_load.grid(row=0, column=0, padx=6)

        self._btn_upload = ttk.Button(
            act_row, text="Upload to Google Sheets",
            command=self._on_upload, state="disabled"
        )
        self._btn_upload.grid(row=0, column=1, padx=6)

        # ── Preview table ──
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

        # ── Log ──
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
        report, errors = read_export_json(path)

        for e in errors:
            self._log_msg(f"ERROR: {e}")

        if not report:
            messagebox.showerror("Load failed", "\n".join(errors))
            return

        self._report = report
        self._populate_table(report)
        self._btn_upload.config(state="normal")
        self._log_msg(f"Loaded {len(report)} player(s): {', '.join(report.keys())}")
        # Auto-fill in-game names from the JSON file
        self._autofill_player_names(report)

    def _autofill_player_names(self, report):
        """Fill in-game name fields from the loaded JSON player names."""
        names = list(report.keys())
        for i, (ig_var, _) in enumerate(self._player_vars):
            ig_var.set(names[i] if i < len(names) else "")
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

        if not messagebox.askyesno(
            "Confirm Upload",
            "Upload data to Google Sheets?\nNew rows will be appended."
        ):
            return

        self._btn_upload.config(state="disabled")
        self._btn_load.config(state="disabled")
        self._log_msg("Uploading...")

        def run():
            try:
                upload_to_sheets(self._report, player_map, self._log_msg)
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
