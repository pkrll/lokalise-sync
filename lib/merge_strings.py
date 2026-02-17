#!/usr/bin/env python3
"""Merge downloaded .strings keys into a target .strings file.

Usage:
    python3 merge_strings.py SOURCE TARGET [--keys-json JSON] [--dry-run] [--backup]

New keys are inserted in alphabetical order among existing keys.
Existing keys are updated in-place. Unmatched target keys are left untouched.
Handles UTF-16 encoded files automatically.
"""
import argparse
import bisect
from fnmatch import fnmatch
import json
import os
import re
import shutil
import sys

STRINGS_PATTERN = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')


def detect_encoding(raw):
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return "utf-16"
    try:
        raw.decode("utf-8")
        return "utf-8"
    except UnicodeDecodeError:
        return "utf-16"


def detect_and_read(path):
    with open(path, "rb") as f:
        raw = f.read()
    encoding = detect_encoding(raw)
    return raw.decode(encoding), encoding


def parse_strings(text):
    pairs = []
    for line in text.splitlines():
        m = STRINGS_PATTERN.match(line)
        if m:
            pairs.append((m.group(1), m.group(2)))
    return pairs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--keys-json", default="")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--backup", action="store_true")
    args = parser.parse_args()

    filter_keys = None
    if args.keys_json:
        filter_keys = json.loads(args.keys_json)

    source_text, _ = detect_and_read(args.source)
    source_pairs = parse_strings(source_text)

    if filter_keys is not None:
        source_pairs = [(k, v) for k, v in source_pairs if any(fnmatch(k, p) for p in filter_keys)]

    if not source_pairs:
        print("[INFO]  No matching keys found in source")
        return

    source_dict = dict(source_pairs)

    if args.dry_run:
        print(f"[INFO]  [DRY RUN] Would merge {len(source_dict)} key(s) into {args.target}:")
        for k, v in source_pairs:
            print(f'  "{k}" = "{v}";')
        return

    if args.backup and os.path.exists(args.target):
        shutil.copy2(args.target, args.target + ".bak")

    target_encoding = "utf-8"
    if os.path.exists(args.target):
        target_text, target_encoding = detect_and_read(args.target)
    else:
        os.makedirs(os.path.dirname(args.target), exist_ok=True)
        target_text = ""

    # Replace matching keys in-place, collect key order for insertion
    updated_keys = set()
    output_lines = []
    key_at_index = []

    for line in target_text.splitlines():
        m = STRINGS_PATTERN.match(line)
        if m:
            key = m.group(1)
            if key in source_dict:
                output_lines.append(f'"{key}" = "{source_dict[key]}";')
                updated_keys.add(key)
            else:
                output_lines.append(line)
            key_at_index.append((len(output_lines) - 1, key))
        else:
            output_lines.append(line)

    # Insert new keys at the correct alphabetical position
    new_keys = [(k, v) for k, v in source_pairs if k not in updated_keys]
    added = len(new_keys)

    if new_keys:
        existing_keys_sorted = [k for _, k in key_at_index]
        insertions = []
        for k, v in new_keys:
            pos = bisect.bisect(existing_keys_sorted, k)
            if pos < len(key_at_index):
                insert_at = key_at_index[pos][0]
            else:
                insert_at = key_at_index[-1][0] + 1 if key_at_index else len(output_lines)
            insertions.append((insert_at, f'"{k}" = "{v}";'))

        insertions.sort(key=lambda x: x[0], reverse=True)
        for idx, line in insertions:
            output_lines.insert(idx, line)

    with open(args.target, "w", encoding=target_encoding) as f:
        f.write("\n".join(output_lines))
        if output_lines:
            f.write("\n")

    updated = len(updated_keys)
    print(f"[OK]    Merged {len(source_dict)} key(s) into {args.target} ({added} new, {updated} updated)")


if __name__ == "__main__":
    main()
