#!/usr/bin/env python3
"""Check persisted iOS 18 project prerequisites; this does not compile Swift."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET


REQUIRED_SOURCES = (
    "App/MixtapeApp.swift",
    "Services/Player/YTMusicNativePlayer.swift",
    "Services/Player/NativePlayerSession.swift",
    "Services/Player/HTTPAudioRangeClient.swift",
    "Services/Player/HTTPAudioResourceLoader.swift",
    "Services/Player/MixtapeHTTPAudioTransfer.swift",
    "Services/Player/StreamFetcher.swift",
    "Services/Player/HTTPAudioRangeClient.swift",
    "Services/Player/HTTPAudioResourceLoader.swift",
    "Services/Player/MixtapeHTTPAudioTransfer.swift",
    "Services/Download/DownloadManager.swift",
    "Utilities/MixtapeIOS18Compat.swift",
)


def check_sources(root: Path) -> dict:
    project = root / "Mixtape.xcodeproj/project.pbxproj"
    source = project.read_text(encoding="utf-8")
    section = source.split("/* Begin XCBuildConfiguration section */", 1)[1].split(
        "/* End XCBuildConfiguration section */", 1
    )[0]
    blocks = re.split(r"(?m)^\t\t[A-F0-9]{24} /\* [^\n]+ \*/ = \{", section)[1:]
    app_configs = [block for block in blocks if "PRODUCT_BUNDLE_IDENTIFIER =" in block]
    if len(app_configs) != 2:
        raise ValueError(f"Expected two Mixtape app configurations; found {len(app_configs)}")
    configurations = []
    for block in app_configs:
        name = re.search(r"(?m)^\s*name = (\w+);", block)
        if not name:
            raise ValueError("App configuration has no name")
        name = name.group(1)
        minima = re.findall(r"(?m)^\s*IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);", block)
        if minima != ["18.0"]:
            raise ValueError(f"{name}: expected iOS 18.0 deployment target, found {minima}")
        conditions = re.findall(r"(?m)^\s*SWIFT_ACTIVE_COMPILATION_CONDITIONS = ([^;]+);", block)
        if len(conditions) != 1 or "IOS18_COMPAT" not in conditions[0].replace('"', "").split():
            raise ValueError(f"{name}: IOS18_COMPAT compilation condition is missing")
        configurations.append(name)
    if sorted(configurations) != ["Debug", "Release"]:
        raise ValueError(f"Expected Debug and Release app configurations, found {configurations}")

    for relative in REQUIRED_SOURCES:
        path = root / relative
        if not path.is_file() or not path.read_text(encoding="utf-8").strip():
            raise ValueError(f"Required source file missing or empty: {relative}")
    for folder in ("Services", "Player", "Utilities"):
        if not re.search(rf"isa = PBXFileSystemSynchronizedRootGroup;\s*path = {folder};", source):
            raise ValueError(f"Expected Xcode synchronized source group: {folder}")
    ET.parse(root / "Mixtape.xcodeproj/xcshareddata/xcschemes/Mixtape.xcscheme")
    with (root / "Resources/Mixtape-Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if "audio" not in info.get("UIBackgroundModes", []):
        raise ValueError("Info.plist is missing the audio background mode")
    for relative in ("Cartfile", "Cartfile.resolved"):
        if not (root / relative).is_file():
            raise ValueError(f"Missing dependency declaration: {relative}")
    return {
        "kind": "static source prerequisites",
        "configurations": configurations,
        "minimumIOS": "18.0",
        "requiredSources": list(REQUIRED_SOURCES),
        "backgroundAudioDeclared": True,
    }


def check_build_settings(path: Path) -> dict:
    settings = json.loads(path.read_text(encoding="utf-8"))
    targets = [entry["buildSettings"] for entry in settings if entry.get("target") == "Mixtape"]
    if len(targets) != 1:
        raise ValueError(f"Expected one Mixtape target in effective build settings; found {len(targets)}")
    target = targets[0]
    if target.get("IPHONEOS_DEPLOYMENT_TARGET") != "18.0":
        raise ValueError("Effective Mixtape IPHONEOS_DEPLOYMENT_TARGET must be 18.0")
    if "IOS18_COMPAT" not in target.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split():
        raise ValueError("Effective Mixtape settings do not contain IOS18_COMPAT")
    return {"minimumIOS": "18.0", "IOS18_COMPAT": True, "configuration": target.get("CONFIGURATION")}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--build-settings", type=Path, help="Optional xcodebuild -showBuildSettings -json output")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = check_sources(args.root.resolve())
        if args.build_settings:
            report["effectiveBuildSettings"] = check_build_settings(args.build_settings)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, IndexError, ET.ParseError, plistlib.InvalidFileException) as error:
        print(f"iOS 18 source validation failed: {error}", file=sys.stderr)
        return 1
    print("iOS 18 source prerequisites passed. Swift compilation and playback are not checked here.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
