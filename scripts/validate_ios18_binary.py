#!/usr/bin/env python3
"""Inspect the app and embedded arm64 binaries' declared minimum iOS versions."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(map(int, (value.split(".") + ["0", "0"])[:3]))


def minimum_versions(binary: Path) -> list[str]:
    result = subprocess.run(
        ["xcrun", "vtool", "-show-build", "-arch", "arm64", str(binary)],
        text=True, capture_output=True, check=False,
    )
    if result.returncode == 0:
        values = re.findall(r"(?m)^\s*minos\s+(\d+\.\d+(?:\.\d+)?)", result.stdout)
        if values:
            platforms = re.findall(r"(?m)^\s*platform\s+(\S+)", result.stdout)
            if platforms and any(value.upper() not in {"IOS", "2"} for value in platforms):
                raise ValueError(f"Unexpected platform in arm64 binary {binary.name}: {platforms}")
            return values
    # Older prebuilt dependencies may use LC_VERSION_MIN_IPHONEOS.
    legacy = subprocess.run(
        ["xcrun", "otool", "-l", "-arch", "arm64", str(binary)],
        text=True, capture_output=True, check=False,
    )
    if legacy.returncode == 0:
        values = re.findall(
            r"cmd LC_VERSION_MIN_IPHONEOS\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)",
            legacy.stdout,
        )
        if values:
            return values
    raise ValueError(f"Could not verify arm64 iOS minimum for {binary.name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    results = []
    problems = []
    with (args.app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("MinimumOSVersion") != "18.0":
        problems.append(f"App MinimumOSVersion is {info.get('MinimumOSVersion')}, expected 18.0")
    candidates = [args.app / info["CFBundleExecutable"]]
    candidates.extend(path for path in args.app.rglob("*.dylib") if path.is_file())
    for framework in args.app.rglob("*.framework"):
        with (framework / "Info.plist").open("rb") as handle:
            framework_info = plistlib.load(handle)
        candidates.append(framework / framework_info["CFBundleExecutable"])
    for binary in sorted(set(candidates)):
        entry = {"binary": str(binary.relative_to(args.app))}
        try:
            entry["minimumIOS"] = minimum_versions(binary)
            if any(version_tuple(value) > (18, 0, 0) for value in entry["minimumIOS"]):
                problems.append(f"{entry['binary']} requires iOS {entry['minimumIOS']}")
        except ValueError as error:
            entry["error"] = str(error)
            problems.append(str(error))
        results.append(entry)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({"binaries": results, "problems": problems}, indent=2) + "\n", encoding="utf-8")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print(f"Verified iOS 18.0 minimum compatibility declarations in {len(results)} arm64 binaries.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
