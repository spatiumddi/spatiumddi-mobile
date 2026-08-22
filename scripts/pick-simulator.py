#!/usr/bin/env python3
"""Print an xcodebuild -destination for an iPhone simulator that exists here.

CI runner images change their simulator line-up with every Xcode bump, so
pinning a model name ("iPhone 17 Pro") breaks on the next image. This picks the
newest iOS runtime with an available iPhone and prints a destination for it.
"""
import json
import subprocess
import sys


def main() -> int:
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True, text=True, check=True,
    ).stdout
    devices = json.loads(raw)["devices"]

    best = None
    for runtime, entries in devices.items():
        if "iOS" not in runtime:
            continue
        # "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> (26, 5)
        version = tuple(int(p) for p in runtime.rsplit(".", 1)[-1].split("-")[1:] if p.isdigit())
        for device in entries:
            if device.get("isAvailable") and "iPhone" in device["name"]:
                if best is None or version > best[0]:
                    best = (version, device["udid"], device["name"])

    if best is None:
        print("no iPhone simulator available", file=sys.stderr)
        return 1

    version, udid, name = best
    print(f"selected {name} on iOS {'.'.join(map(str, version))}", file=sys.stderr)
    print(f"platform=iOS Simulator,id={udid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
