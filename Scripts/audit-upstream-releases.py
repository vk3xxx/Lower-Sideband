#!/usr/bin/env python3
"""Audit pinned Reticulum references and report newer tagged releases.

This developer-only tool never modifies submodules or application source. It
produces a machine-readable report suitable for a scheduled/manual CI job.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Support" / "UpstreamCompatibility.json"
VERSION = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$")


def run(*arguments: str, cwd: pathlib.Path | None = None) -> str:
    return subprocess.run(
        arguments,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout.strip()


def version_key(value: str) -> tuple[int, int, int] | None:
    match = VERSION.match(value)
    return tuple(map(int, match.groups())) if match else None


def latest_tag(repository: str) -> str:
    output = run("git", "ls-remote", "--tags", "--refs", repository)
    tags = [line.rsplit("refs/tags/", 1)[-1] for line in output.splitlines()]
    versions = [(version_key(tag), tag) for tag in tags]
    valid = [item for item in versions if item[0] is not None]
    return max(valid, default=((0, 0, 0), "unknown"))[1]


def audit(check_remote: bool) -> dict[str, Any]:
    manifest = json.loads(MANIFEST.read_text())
    references = []
    for reference in manifest["references"]:
        path = ROOT / reference["path"]
        actual_commit = run("git", "rev-parse", "HEAD", cwd=path)
        actual_tag = run("git", "describe", "--tags", "--exact-match", cwd=path)
        latest = latest_tag(reference["repository"]) if check_remote else None
        references.append(
            {
                **reference,
                "actualCommit": actual_commit,
                "actualTag": actual_tag.removeprefix("v"),
                "pinValid": actual_commit == reference["commit"]
                and actual_tag.removeprefix("v") == reference["version"],
                "latestTaggedRelease": latest,
                "updateAvailable": bool(
                    latest
                    and version_key(latest)
                    and version_key(reference["version"])
                    and version_key(latest) > version_key(reference["version"])
                ),
            }
        )
    return {
        "schema": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "remoteChecked": check_remote,
        "pinsValid": all(item["pinValid"] for item in references),
        "updatesAvailable": [item["name"] for item in references if item["updateAvailable"]],
        "references": references,
        "requiredEvidence": manifest["requiredEvidence"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-only", action="store_true")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    try:
        report = audit(not args.local_only)
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Upstream compatibility audit failed: {error}", file=sys.stderr)
        return 1
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    print(encoded, end="")
    return 0 if report["pinsValid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
