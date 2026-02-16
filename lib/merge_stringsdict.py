#!/usr/bin/env python3
"""Merge downloaded .stringsdict keys into a target .stringsdict file.

Usage:
    python3 merge_stringsdict.py SOURCE TARGET [--keys-json JSON] [--dry-run] [--backup]

Uses plistlib for robust plist manipulation.
"""
import argparse
import json
import os
import plistlib
import shutil
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--keys-json", default="")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--backup", action="store_true")
    args = parser.parse_args()

    with open(args.source, "rb") as f:
        source_data = plistlib.load(f)

    # Filter to specific keys if provided
    if args.keys_json:
        keys_to_keep = set(json.loads(args.keys_json))
        source_data = {k: v for k, v in source_data.items() if k in keys_to_keep}

    if not source_data:
        print("[INFO]  No matching stringsdict keys found in source")
        return

    if args.dry_run:
        print(f"[INFO]  [DRY RUN] Would merge {len(source_data)} stringsdict key(s) into {args.target}:")
        for key in source_data:
            print(f"  {key}")
        return

    if args.backup and os.path.exists(args.target):
        shutil.copy2(args.target, args.target + ".bak")

    if os.path.exists(args.target):
        with open(args.target, "rb") as f:
            target_data = plistlib.load(f)
    else:
        os.makedirs(os.path.dirname(args.target), exist_ok=True)
        target_data = {}

    updated = 0
    added = 0
    for key, value in source_data.items():
        if key in target_data:
            updated += 1
        else:
            added += 1
        target_data[key] = value

    with open(args.target, "wb") as f:
        plistlib.dump(target_data, f)

    print(f"[OK]    Merged {len(source_data)} stringsdict key(s) into {args.target} ({added} new, {updated} updated)")


if __name__ == "__main__":
    main()
