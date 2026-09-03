#!/usr/bin/env python3
"""Materialize exact external validation repositories declared by reference-lock.json."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

SHA1 = re.compile(r"^[0-9a-f]{40}$")


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain an object")
    return value


def validate_repository(repository: dict[str, Any]) -> tuple[str, str, str]:
    identifier = str(repository["id"])
    url = str(repository["url"])
    revision = str(repository["revision"])
    parsed = urlparse(url)
    if (
        not identifier
        or "/" in identifier
        or identifier in {".", ".."}
        or parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or not parsed.path.endswith(".git")
        or not SHA1.fullmatch(revision)
    ):
        raise ValueError(f"Unsafe pinned repository declaration: {identifier}")
    return identifier, url, revision


def run(*arguments: str, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        list(arguments),
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def materialize(destination: Path, url: str, revision: str, replace: bool) -> None:
    if destination.exists():
        if not replace:
            actual = run("git", "rev-parse", "HEAD", cwd=destination)
            dirty = run("git", "status", "--porcelain", cwd=destination)
            if actual == revision and not dirty:
                return
            raise RuntimeError(
                f"{destination} exists at {actual or 'unknown'}, expected {revision}; "
                "pass --replace to recreate it"
            )
        shutil.rmtree(destination)

    destination.parent.mkdir(parents=True, exist_ok=True)
    run("git", "init", "--quiet", str(destination))
    run("git", "remote", "add", "origin", url, cwd=destination)
    run("git", "fetch", "--quiet", "--depth", "1", "origin", revision, cwd=destination)
    run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=destination)
    actual = run("git", "rev-parse", "HEAD", cwd=destination)
    if actual != revision:
        shutil.rmtree(destination)
        raise RuntimeError(f"Fetched {actual}, expected {revision}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--lock",
        type=Path,
        default=Path(__file__).with_name("reference-lock.json"),
    )
    parser.add_argument(
        "--sources-root",
        type=Path,
        default=Path(".build/validation-sources"),
    )
    parser.add_argument("--replace", action="store_true")
    arguments = parser.parse_args()

    lock = load_json(arguments.lock)
    for repository in lock.get("repositories", []):
        identifier, url, revision = validate_repository(repository)
        materialize(arguments.sources_root / identifier, url, revision, arguments.replace)
        print(f"{identifier}: {revision}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
