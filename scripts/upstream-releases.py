#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

DEFAULT_UPSTREAM_REPO = "worklouder/input-releases"
STABLE_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
PRERELEASE_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)-(.+)$")
NO_PRERELEASE_SUFFIX_RANKS_HIGHER = 1
HAS_PRERELEASE_SUFFIX_RANKS_LOWER = 0


def semver_key(match):
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    prerelease = match.group(4) if match.re is PRERELEASE_TAG else None
    if prerelease is None:
        return (major, minor, patch, NO_PRERELEASE_SUFFIX_RANKS_HIGHER, ())
    parts = tuple(
        int(part) if part.isdigit() else part for part in re.split(r"[.-]", prerelease)
    )
    return (major, minor, patch, HAS_PRERELEASE_SUFFIX_RANKS_LOWER, parts)


def ships_windows_installer(release):
    return any(
        asset["name"].startswith("input-Setup-") and asset["name"].endswith(".exe")
        for asset in release.get("assets", [])
    )


def fetch_releases(repo):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases?per_page=100",
        headers={"Accept": "application/vnd.github+json"},
    )
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def newest_version(releases, channel):
    tag_pattern = STABLE_TAG if channel == "stable" else PRERELEASE_TAG
    newest = None
    for release in releases:
        if release.get("draft") or not ships_windows_installer(release):
            continue
        match = tag_pattern.match(release.get("tag_name", ""))
        if not match:
            continue
        if newest is None or semver_key(match) > semver_key(newest):
            newest = match
    return newest


def plan(releases):
    candidates = []

    newest_stable = newest_version(releases, "stable")
    if newest_stable:
        candidates.append(
            {
                "version": newest_stable.group(0).lstrip("v"),
                "channel": "stable",
                "prerelease": False,
            }
        )

    newest_prerelease = newest_version(releases, "prerelease")
    if newest_prerelease and (
        newest_stable is None
        or semver_key(newest_prerelease) > semver_key(newest_stable)
    ):
        candidates.append(
            {
                "version": newest_prerelease.group(0).lstrip("v"),
                "channel": "prerelease",
                "prerelease": True,
            }
        )

    return candidates


def main():
    parser = argparse.ArgumentParser(
        description="Query the upstream Input release feed."
    )
    parser.add_argument("command", choices=("latest", "plan"))
    parser.add_argument("--channel", choices=("stable", "prerelease"), default="stable")
    parser.add_argument("--repo", default=os.environ.get("UPSTREAM_REPO", DEFAULT_UPSTREAM_REPO))
    args = parser.parse_args()

    try:
        releases = fetch_releases(args.repo)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as error:
        print(f"could not reach {args.repo}: {error}", file=sys.stderr)
        return 1

    if args.command == "plan":
        print(json.dumps(plan(releases)))
        return 0

    newest = newest_version(releases, args.channel)
    if newest is None:
        print(f"no {args.channel} release found in {args.repo}", file=sys.stderr)
        return 1

    print(newest.group(0).lstrip("v"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
