#!/usr/bin/env python3
"""Append verified, content-addressed toolchains to the dedicated cache release."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def gh_json(*arguments):
    return json.loads(subprocess.check_output(["gh", *arguments], text=True))


def sha256(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--tag", default="linux-toolchains-v1")
    parser.add_argument("--source-commit", default=os.environ.get("GITHUB_SHA"), required=False)
    parser.add_argument("--source-run", default=os.environ.get("GITHUB_RUN_ID"), required=False)
    parser.add_argument("--output", type=Path, default=Path("published-toolchains.json"))
    args = parser.parse_args()
    if not (args.source_commit and args.source_run):
        parser.error("source commit and source run are required")
    repository = os.environ["GH_REPO"]
    release_path = "repos/{}/releases/tags/{}".format(repository, args.tag)
    # The tag/release is created once, separately from Qt SDK publishing.
    # Never create a moving or per-build tag here.
    release = gh_json("api", release_path)
    if release["draft"]:
        raise ValueError("The dedicated toolchain cache release is still a draft")
    assets = {asset["name"]: asset for asset in release["assets"]}
    archives = sorted(list(args.directory.glob("*.tar.xz")) + list(args.directory.glob("*.tar.gz")))
    if not archives:
        raise ValueError("No verified toolchain archives to publish")
    records = []
    with tempfile.TemporaryDirectory(prefix="qt-toolchain-cache-") as temporary:
        work = Path(temporary)

        def refresh():
            assets.update({a["name"]: a for a in gh_json("api", release_path)["assets"]})

        def download(asset, destination):
            with destination.open("wb") as stream:
                subprocess.check_call(["gh", "api", "-H", "Accept: application/octet-stream",
                                       "repos/{}/releases/assets/{}".format(repository, asset["id"])], stdout=stream)

        def upload(path):
            checksum = sha256(path)
            if path.name not in assets:
                result = subprocess.run(["gh", "release", "upload", args.tag, str(path)])
                refresh()
                if result.returncode and path.name not in assets:
                    raise subprocess.CalledProcessError(result.returncode, result.args)
            asset = assets[path.name]
            existing_digest = asset.get("digest")
            if existing_digest:
                if existing_digest != "sha256:" + checksum:
                    raise ValueError("Refusing to overwrite different cache content: " + path.name)
            else:
                check = work / ("verify-" + path.name)
                download(asset, check)
                if sha256(check) != checksum:
                    raise ValueError("Existing cache asset checksum mismatch: " + path.name)
                check.unlink()
            return asset

        for archive in archives:
            checksum = sha256(archive)
            suffix = ".tar.xz" if archive.name.endswith(".tar.xz") else ".tar.gz"
            name = archive.name[:-len(suffix)] + "-" + checksum[:12] + suffix
            staged = work / name
            try:
                os.link(archive, staged)
            except OSError:
                shutil.copyfile(archive, staged)
            asset = upload(staged)
            metadata_name = name + ".json"
            if metadata_name in assets:
                previous = work / metadata_name
                download(assets[metadata_name], previous)
                record = json.loads(previous.read_text())
                if record["sha256"] != checksum or record["asset_id"] != asset["id"]:
                    raise ValueError("Existing cache provenance does not match its archive")
            else:
                record = dict(schema=1, tag=args.tag, filename=name, original_filename=archive.name,
                              sha256=checksum, size=archive.stat().st_size, asset_id=asset["id"],
                              api_url=asset["url"], source_commit=args.source_commit,
                              source_run=str(args.source_run), source_repository=repository)
                metadata = work / metadata_name
                metadata.write_text(json.dumps(record, indent=2) + "\n")
                upload(metadata)
            sums = work / (name + ".sha256")
            sums.write_text(checksum + "  " + name + "\n")
            upload(sums)
            records.append(record)
            print("Cached:", name, "asset", asset["id"])
        # Keep upstream compiler notices/version/source records alongside the
        # unchanged original archives, also under immutable content names.
        for companion in sorted(args.directory.iterdir()):
            if companion.suffix not in (".json", ".txt") or not companion.is_file():
                continue
            name = companion.stem + "-" + sha256(companion)[:12] + companion.suffix
            staged = work / name
            shutil.copyfile(companion, staged)
            upload(staged)
    args.output.write_text(json.dumps(records, indent=2) + "\n")


if __name__ == "__main__":
    main()
