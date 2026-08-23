#!/usr/bin/env python3
"""Merge the compiler's extracted strings into Localizable.xcstrings.

Xcode populates a string catalogue when you build in the IDE. `xcodebuild` emits
the same `.stringsdata` but does not merge it, so a catalogue built only from
command-line builds — CI, or this repo's own scripts — stays empty and every new
string silently goes untranslated.

This does the merge, so the committed catalogue is a true list of what the app
says. It never removes a key: a string that vanished from a build may simply be
behind a feature the build did not compile, and dropping a translator's work on
that guess is not a trade worth making.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "SpatiumDDI/SpatiumDDI/Localizable.xcstrings"


def stringsdata_files(build_root: pathlib.Path):
    """Only this app's own strings — not those of every package it links."""
    return [
        p
        for p in build_root.rglob("*.stringsdata")
        if "/SpatiumDDI.build/" in str(p) and p.name != "ExtractedAppShortcutsMetadata.stringsdata"
    ]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: build-string-catalog.py <derived-data-build-dir>", file=sys.stderr)
        return 2
    build_root = pathlib.Path(sys.argv[1])
    if not build_root.is_dir():
        print(f"not a directory: {build_root}", file=sys.stderr)
        return 2

    catalog = json.loads(CATALOG.read_text()) if CATALOG.exists() else {}
    catalog.setdefault("sourceLanguage", "en")
    catalog.setdefault("version", "1.0")
    strings = catalog.setdefault("strings", {})

    found = 0
    for path in stringsdata_files(build_root):
        # `.stringsdata` is a plist variant Python's plistlib rejects outright,
        # so it goes through plutil, which reads it.
        try:
            converted = subprocess.run(
                ["plutil", "-convert", "json", "-o", "-", str(path)],
                capture_output=True,
                check=True,
            )
            data = json.loads(converted.stdout)
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            continue
        for entries in (data.get("tables") or {}).values():
            for entry in entries:
                key = entry.get("key")
                if not key:
                    continue
                found += 1
                existing = strings.setdefault(key, {})
                comment = entry.get("comment")
                if comment and "comment" not in existing:
                    existing["comment"] = comment
                # The source language needs no translation unit: the key *is*
                # the English text. Marking it otherwise would show every
                # string as untranslated in Xcode's own progress figure.
                existing.setdefault("extractionState", "extracted_with_value")

    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"{len(strings)} keys in the catalogue ({found} extractions seen)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
