#!/usr/bin/env python3
"""Report when FFmpeg or QuickJS-NG has a newer stable release than the pinned submodule.

Compares the commit each submodule is pinned to (from `git ls-tree`, so the submodules don't need
to be checked out) with the newest stable tag upstream (`git ls-remote`). With --open-issue it
opens one GitHub issue per tool, or updates that tool's open issue if a newer version appeared
since. Bumping stays a manual step: move the submodule, run the media workflow, publish.

usage: check_upstream.py [--open-issue]
Stdlib only (plus the git and gh CLIs).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess

TOOLS = (
    # name, submodule path, upstream URL, stable-tag pattern (groups are the version numbers)
    ("FFmpeg", "media/ffmpeg", "https://github.com/FFmpeg/FFmpeg.git", re.compile(r"^n(\d+)\.(\d+)(?:\.(\d+))?$")),
    ("QuickJS-NG", "media/quickjs", "https://github.com/quickjs-ng/quickjs.git", re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")),
)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def pinned_commit(path: str) -> str:
    # Index entry "160000 <sha> 0\t<path>"; in a CI checkout the index matches HEAD.
    entry = git("ls-files", "--stage", "--", path).split()
    if len(entry) < 2 or entry[0] != "160000":
        raise SystemExit(f"error: {path} is not a submodule in this checkout")
    return entry[1]


def stable_tags(url: str, pattern: re.Pattern) -> dict[str, tuple[tuple[int, ...], str]]:
    """tag -> (version tuple, commit sha). Annotated tags resolve to the commit via ^{}."""
    tags: dict[str, tuple[tuple[int, ...], str]] = {}
    peeled: dict[str, str] = {}
    for line in git("ls-remote", "--tags", url).splitlines():
        sha, ref = line.split("\t")
        name = ref.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            peeled[name[:-3]] = sha
            continue
        match = pattern.match(name)
        if match:
            tags[name] = (tuple(int(g or 0) for g in match.groups()), sha)
    return {name: (version, peeled.get(name, sha)) for name, (version, sha) in tags.items()}


def upsert_issue(tool: str, title: str, body: str) -> None:
    issues = json.loads(subprocess.run(
        ["gh", "issue", "list", "--state", "open", "--limit", "100", "--json", "number,title"],
        check=True, capture_output=True, text=True).stdout)
    prefix = f"Upstream update: {tool} "
    existing = next((i for i in issues if i["title"].startswith(prefix)), None)
    if existing and existing["title"] == title:
        print(f"  issue #{existing['number']} already open")
    elif existing:
        subprocess.run(["gh", "issue", "edit", str(existing["number"]), "--title", title, "--body", body], check=True)
        print(f"  updated issue #{existing['number']}")
    else:
        subprocess.run(["gh", "issue", "create", "--title", title, "--body", body], check=True)
        print("  opened an issue")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--open-issue", action="store_true")
    args = parser.parse_args()

    for tool, path, url, pattern in TOOLS:
        pinned = pinned_commit(path)
        tags = stable_tags(url, pattern)
        newest = max(tags, key=lambda t: tags[t][0])
        current = next((t for t, (_, sha) in tags.items() if sha == pinned), None)
        print(f"{tool}: pinned {current or pinned[:12]}, newest stable {newest}")
        if current and tags[current][0] >= tags[newest][0]:
            continue
        title = f"Upstream update: {tool} {newest} is available"
        body = (f"`{path}` is pinned to **{current or pinned}**; {tool} **{newest}** is the newest stable release.\n\n"
                "To update:\n"
                f"1. `git -C {path} fetch --depth 1 origin tag {newest} && git -C {path} checkout {newest}`\n"
                f"2. Commit the submodule bump and run **Build Media Tools** (workflow_dispatch) to build and smoke-test it.\n"
                "3. Re-run it with **publish** ticked. INTERSECT picks up the new release on its next tools check.\n\n"
                "_Opened by the weekly check-upstream workflow._")
        if args.open_issue:
            upsert_issue(tool, title, body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
