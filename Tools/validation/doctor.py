#!/usr/bin/env python3
"""Verify the pinned NumiTissue external-reference environment without running simulations."""

from __future__ import annotations

import argparse
import importlib
import importlib.metadata
import json
import platform
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Check:
    identifier: str
    expected: str
    actual: str | None
    status: str
    detail: str = ""


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def package_checks(lock: dict[str, Any]) -> list[Check]:
    checks: list[Check] = []
    for package in lock.get("packages", []):
        distribution = str(package["distribution"])
        import_name = str(package["importName"])
        expected = str(package["version"])
        try:
            actual = importlib.metadata.version(distribution)
            importlib.import_module(import_name)
        except (importlib.metadata.PackageNotFoundError, ImportError) as error:
            checks.append(Check(distribution, expected, None, "missing", str(error)))
            continue
        status = "ok" if actual == expected else "version-mismatch"
        checks.append(Check(distribution, expected, actual, status))
    return checks


def git_output(*arguments: str, cwd: Path) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def repository_checks(lock: dict[str, Any], sources_root: Path) -> list[Check]:
    checks: list[Check] = []
    for repository in lock.get("repositories", []):
        identifier = str(repository["id"])
        expected = str(repository["revision"])
        directory = sources_root / identifier
        if not directory.is_dir():
            checks.append(Check(identifier, expected, None, "missing", str(directory)))
            continue
        try:
            actual = git_output("rev-parse", "HEAD", cwd=directory)
            dirty = bool(git_output("status", "--porcelain", cwd=directory))
        except (OSError, subprocess.CalledProcessError) as error:
            checks.append(Check(identifier, expected, None, "invalid-checkout", str(error)))
            continue
        if actual != expected:
            status = "revision-mismatch"
        elif dirty:
            status = "dirty"
        else:
            status = "ok"
        checks.append(Check(identifier, expected, actual, status))
    return checks


def python_check(lock: dict[str, Any]) -> Check:
    expected = (
        f">={lock['python']['minimum']},"
        f"<{lock['python']['maximumExclusive']}"
    )
    actual = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    minimum = tuple(int(x) for x in str(lock["python"]["minimum"]).split("."))
    maximum = tuple(int(x) for x in str(lock["python"]["maximumExclusive"]).split("."))
    current = (sys.version_info.major, sys.version_info.minor)
    status = "ok" if minimum <= current < maximum else "version-mismatch"
    return Check("python", expected, actual, status)


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
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()

    lock = load_json(arguments.lock)
    checks = [python_check(lock)]
    checks.extend(package_checks(lock))
    checks.extend(repository_checks(lock, arguments.sources_root))
    passing = all(item.status == "ok" for item in checks)
    report = {
        "schemaVersion": 1,
        "passing": passing,
        "platform": {
            "python": sys.version,
            "implementation": platform.python_implementation(),
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "lock": str(arguments.lock),
        "sourcesRoot": str(arguments.sources_root),
        "checks": [asdict(item) for item in checks],
    }
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 0 if passing else 2


if __name__ == "__main__":
    raise SystemExit(main())
