#!/usr/bin/env python3
"""Embed and validate Qt application icons and product metadata before archiving."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile


PRODUCTS = {
    "designer": ("Qt Designer", "org.qt-project.Designer", "qttools/src/designer/src/designer/designer.icns"),
    "assistant": ("Qt Assistant", "org.qt-project.assistant", "qttools/src/assistant/assistant/assistant.icns"),
    "linguist": ("Qt Linguist", "org.qt-project.Linguist", "qttools/src/linguist/linguist/linguist.icns"),
    "qdbusviewer": ("Qt D-Bus Viewer", "org.qt-project.dbusviewer", "qttools/src/qdbus/qdbusviewer/images/qdbusviewer.icns"),
    "qml": ("QML Runtime", "org.qt-project.qml", "qtdeclarative/tools/qml/resources/qml.icns"),
    "qmlscene": ("QML Scene Viewer", "org.qt-project.qmlscene", "qtdeclarative/tools/qml/resources/qml.icns"),
    "pixeltool": ("Qt Pixel Tool", "org.qt-project.pixeltool", None),
    "qdistancefieldgenerator": ("Qt Distance Field Generator", "org.qt-project.qdistancefieldgenerator", None),
}


def check_icon(path):
    data = path.read_bytes()
    if len(data) <= 8 or data[:4] != b"icns" or struct.unpack_from(">I", data, 4)[0] != len(data):
        raise ValueError("Invalid or missing macOS icon: " + str(path))


def generic_icon(source, directory):
    """Convert the existing upstream Qt logo with macOS's native icon tools."""
    iconset = directory / "Qt.iconset"
    iconset.mkdir()
    logo = source / "qtdeclarative/examples/quick/shared/images/qt-logo.png"
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = "icon_{}x{}{}.png".format(size, size, "@2x" if scale == 2 else "")
            subprocess.check_call(["sips", "-z", str(size * scale), str(size * scale),
                                   str(logo), "--out", str(iconset / name)], stdout=subprocess.DEVNULL)
    output = directory / "Qt.icns"
    subprocess.check_call(["iconutil", "-c", "icns", str(iconset), "-o", str(output)])
    check_icon(output)
    return output


def verify_bundle(app, version):
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleIdentifier", "CFBundleExecutable",
                "CFBundleIconFile", "CFBundleShortVersionString", "CFBundleVersion", "NSHumanReadableCopyright"):
        if not info.get(key) or "@" in str(info[key]):
            raise ValueError("{}: missing or unresolved {}".format(app, key))
    if info["CFBundleShortVersionString"] != version or info["CFBundleVersion"] != version:
        raise ValueError("Wrong product version in " + str(app))
    executable = contents / "MacOS" / info["CFBundleExecutable"]
    if not executable.is_file() or (sys.platform == "darwin" and not os.access(executable, os.X_OK)):
        raise ValueError("Missing or non-executable application binary: " + str(executable))
    icon = Path(info["CFBundleIconFile"])
    if icon.name != str(icon):
        raise ValueError("Icon must name a bundle resource: " + str(app))
    if not icon.suffix:
        icon = icon.with_suffix(".icns")
    check_icon(contents / "Resources" / icon)
    for document in info.get("CFBundleDocumentTypes", []):
        document_icon = document.get("CFBundleTypeIconFile")
        if document_icon:
            path = contents / "Resources" / document_icon
            if not path.suffix:
                path = path.with_suffix(".icns")
            check_icon(path)
    return info


def embed_bundle(app, source, version, fallback):
    contents = app / "Contents"
    plist = contents / "Info.plist"
    with plist.open("rb") as stream:
        info = plistlib.load(stream)
    product, identifier, icon_source = PRODUCTS.get(
        app.stem.lower(), ("Qt " + app.stem, "org.qt-project." + app.stem.lower(), None))
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    if icon_source:
        icon = source / icon_source
        check_icon(icon)
        shutil.copy2(icon, resources / icon.name)
        info["CFBundleIconFile"] = icon.name
        if app.stem.lower() == "designer":
            shutil.copy2(icon.with_name("uifile.icns"), resources / "uifile.icns")
    else:
        existing = resources / str(info.get("CFBundleIconFile", ""))
        if not existing.suffix:
            existing = existing.with_suffix(".icns")
        try:
            check_icon(existing)
        except (OSError, ValueError):
            icon = fallback()
            shutil.copy2(icon, resources / icon.name)
            info["CFBundleIconFile"] = icon.name
    executable = info.get("CFBundleExecutable", app.stem)
    if not (contents / "MacOS" / executable).is_file():
        candidates = [p.name for p in (contents / "MacOS").iterdir() if p.is_file()]
        if len(candidates) != 1:
            raise ValueError("Cannot identify the application executable: " + str(app))
        executable = candidates[0]
    info.update(CFBundleName=product, CFBundleDisplayName=product,
                CFBundleShortVersionString=version, CFBundleVersion=version,
                CFBundleInfoDictionaryVersion="6.0", CFBundlePackageType="APPL",
                CFBundleExecutable=executable, CFBundleGetInfoString=product + " " + version,
                NSHighResolutionCapable=True)
    info.setdefault("CFBundleIdentifier", identifier)
    info.setdefault("NSHumanReadableCopyright", "The Qt Company Ltd.")
    with plist.open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)
    verify_bundle(app, version)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--version", default="5.15.17")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--resign", action="store_true", help="Renew bundle signatures after universal merging")
    args = parser.parse_args()
    apps = sorted(p for p in args.sdk.rglob("*.app") if p.is_dir() and not p.is_symlink())
    if not apps:
        raise ValueError("No macOS application bundles found in " + str(args.sdk))
    with tempfile.TemporaryDirectory(prefix="qt-macos-icons-") as temporary:
        cached = []

        def fallback():
            if not cached:
                cached.append(generic_icon(args.source, Path(temporary)))
            return cached[0]

        for app in apps:
            if not args.verify_only:
                embed_bundle(app, args.source, args.version, fallback)
            if not args.verify_only or args.resign:
                # plist/icon changes invalidate any existing resource seal.
                subprocess.check_call(["codesign", "--force", "--sign", "-", str(app)])
            verify_bundle(app, args.version)
            if sys.platform == "darwin":
                subprocess.check_call(["codesign", "--verify", "--strict", str(app)])
            print("Verified icon and product metadata:", app.name)


if __name__ == "__main__":
    main()
