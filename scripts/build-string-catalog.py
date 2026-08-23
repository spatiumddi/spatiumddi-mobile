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
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "SpatiumDDI/SpatiumDDI/Localizable.xcstrings"


def serialise(catalog: dict) -> str:
    """Write the catalogue the way Xcode writes it.

    Xcode serialises `.xcstrings` through Foundation's `JSONSerialization` with
    `.prettyPrinted` and `.sortedKeys`, which puts a space *before* the colon.
    Python's `json` does not. Emitting the other format means an IDE build and a
    run of this script rewrite every line against each other, so two people
    working either way produce a whole-file conflict on the one file translators
    own — and no reviewer can see which key actually changed.
    """
    body = json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True)
    # Only the structural separator, never one inside a string value.
    out = []
    for line in body.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith('"'):
            head, sep, tail = line.partition('" : ')
            if not sep:
                head, sep, tail = line.partition('": ')
                if sep:
                    line = f'{head}" : {tail}'
        out.append(line)
    return "\n".join(out) + "\n"


def stringsdata_files(build_root: pathlib.Path):
    """Only the app target's strings.

    Not a substring test on the path: Xcode nests each target's directory inside
    the *project* directory, so `.../SpatiumDDI.build/Debug-iphonesimulator/
    SpatiumDDIUITests.build/...` contains "/SpatiumDDI.build/" too. Matching that
    way pulls in both test bundles, and the first literal anyone writes in a test
    would be merged into the catalogue and shipped to translators — permanently,
    since this script never removes a key.

    The app target's own directory is the parent-of-parent of `Objects-normal`.
    """
    root = build_root / "Intermediates.noindex" / "SpatiumDDI.build"
    if not root.is_dir():
        return []
    return [
        p
        for p in root.rglob("*.stringsdata")
        if p.parents[2].name == "SpatiumDDI.build"
        and p.name != "ExtractedAppShortcutsMetadata.stringsdata"
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
    unreadable: list[str] = []
    for path in stringsdata_files(build_root):
        # `.stringsdata` is JSON — plistlib rejects it for that reason, not
        # because it is an exotic plist. Reading it directly avoids forking a
        # `plutil` per file to convert JSON into JSON.
        try:
            data = json.loads(path.read_bytes())
        except (json.JSONDecodeError, OSError) as error:
            unreadable.append(f"{path.name}: {error}")
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

    for problem in unreadable:
        print(f"warning: could not read {problem}", file=sys.stderr)

    # A run that read nothing is a broken run, not an up-to-date catalogue —
    # wrong path, an unbuilt target, or a format change. Exiting 0 here is
    # exactly the silent staleness this script exists to prevent, and would let
    # `build-string-catalog.py … && git diff --exit-code` pass in CI while the
    # catalogue rotted.
    if found == 0:
        print(
            f"error: no strings extracted from {build_root}. "
            "Build the app target first, and check the path is a DerivedData Build directory.",
            file=sys.stderr,
        )
        return 1

    CATALOG.write_text(serialise(catalog))
    print(f"{len(strings)} keys in the catalogue ({found} extractions seen)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
