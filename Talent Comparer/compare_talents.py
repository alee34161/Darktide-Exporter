"""
compare_talents.py
===================
Compare two pasted-in lists of talent keys (like the snippets copied out
of lookup.json or a PDI export's talents_selected block) and print/save
the keys that appear in BOTH.

Usage:
    python compare_talents.py
        -> opens an editor-style paste prompt for List A, then List B

    python compare_talents.py file_a.json file_b.json
        -> still works if you'd rather point at two saved files

    Add --out shared.json to either mode to also save the result.

Paste mode accepts:
    - A full JSON object:
          { "cryptic_weakspot_kills_grant_power": "1 (number)", ... }
    - Just the inner lines, comma or no comma, braces optional:
          "cryptic_weakspot_kills_grant_power": "1 (number)",
          "cryptic_ranged_stacking_toughness": "1 (number)"
    - A bare list of keys, one per line, with or without quotes:
          cryptic_weakspot_kills_grant_power
          cryptic_ranged_stacking_toughness

For each list, paste your content then press Enter on an empty line to
finish that list.
"""

import json
import re
import sys
import argparse


def load_json_from_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def parse_pasted_keys(text):
    """
    Best-effort parser for pasted talent blobs. Tries strict JSON first
    (after wrapping in braces if needed), then falls back to pulling out
    anything that looks like a key via regex line-by-line.
    """
    text = text.strip()
    if not text:
        return {}

    # Try 1: as-is, valid JSON object
    candidates = [text]
    # Try 2: wrap in braces in case the user pasted just the inner lines
    if not text.startswith("{"):
        candidates.append("{" + text.rstrip(",") + "}")

    for candidate in candidates:
        try:
            data = json.loads(candidate)
            if isinstance(data, dict):
                return data
            if isinstance(data, list):
                return {str(k): True for k in data}
        except json.JSONDecodeError:
            continue

    # Fallback: regex-extract quoted "key": value pairs, or bare key lines
    result = {}
    kv_pattern = re.compile(r'"([^"]+)"\s*:\s*("(?:[^"\\]|\\.)*"|[\w.\-]+)')
    for match in kv_pattern.finditer(text):
        key, val = match.group(1), match.group(2).strip('"')
        result[key] = val

    if not result:
        # Last resort: treat each non-empty line as a bare key
        for line in text.splitlines():
            line = line.strip().strip(",").strip('"').strip()
            if line and line not in ("{", "}"):
                # strip a trailing ": value" if present
                key = line.split(":", 1)[0].strip().strip('"')
                if key:
                    result[key] = True

    return result


def prompt_paste(label):
    print(f"\nPaste {label} below, then press Enter on a blank line to finish:")
    lines = []
    while True:
        try:
            line = input()
        except EOFError:
            break
        if line.strip() == "":
            break
        lines.append(line)
    return parse_pasted_keys("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description="Find shared keys between two talent lists.")
    parser.add_argument("file_a", nargs="?", help="Path to first JSON file (omit to paste instead)")
    parser.add_argument("file_b", nargs="?", help="Path to second JSON file (omit to paste instead)")
    parser.add_argument("--out", help="Optional path to write the shared-keys JSON to")
    args = parser.parse_args()

    if args.file_a and args.file_b:
        data_a = load_json_from_file(args.file_a)
        data_b = load_json_from_file(args.file_b)
    else:
        data_a = prompt_paste("List A")
        data_b = prompt_paste("List B")

    if not isinstance(data_a, dict) or not isinstance(data_b, dict):
        print("Error: both inputs must resolve to key/value data.")
        sys.exit(1)

    keys_a = set(data_a.keys())
    keys_b = set(data_b.keys())
    shared = sorted(keys_a & keys_b)

    print(f"\nList A: {len(keys_a)} keys")
    print(f"List B: {len(keys_b)} keys")
    print(f"Shared: {len(shared)} keys\n")

    for k in shared:
        print(f"  {k}")

    if args.out:
        # Build an output object preserving the value from List A (fallback to B)
        result = {k: data_a.get(k, data_b.get(k)) for k in shared}
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
        print(f"\nSaved shared keys to {args.out}")


if __name__ == "__main__":
    main()
