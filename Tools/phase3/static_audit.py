#!/usr/bin/env python3
"""Fail-closed source checks for the Metal 4 validation boundary.

This is intentionally a source audit, not a qualification result.  Hardware
execution, differential evidence, and promotion authorization are separate
steps in the Phase 3 workflow.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class AuditCheck:
    identifier: str
    passed: bool
    required: bool
    detail: str


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def run_git(root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def check_files(root: Path, paths: Iterable[str]) -> AuditCheck:
    missing = [path for path in paths if not (root / path).is_file()]
    return AuditCheck(
        "phase3.required-files",
        not missing,
        True,
        "all required files are present"
        if not missing
        else "missing: " + ", ".join(missing),
    )


def check_kernel_coverage(root: Path) -> AuditCheck:
    library = read(root / "Sources/NumiTissueMetal/MetalShaderLibrary.swift")
    catalog = read(root / "Sources/NumiTissueMetal/Metal4ExecutionContracts.swift")
    kernel_cases = re.findall(
        r"^\s*case\s+(\w+)\s*=\s*\"([^\"]+)\"",
        library,
        re.MULTILINE,
    )
    kernels = [raw_name for _, raw_name in kernel_cases]
    names = re.findall(r"kernel\s+void\s+([A-Za-z0-9_]+)", "\n".join(
        read(path) for path in sorted((root / "Sources/NumiTissueMetal/Shaders").glob("*.metal"))
    ))
    missing_shader = sorted(set(kernels) - set(names))
    missing_catalog = [
        raw_name for case_name, raw_name in kernel_cases
        if not re.search(r"\." + re.escape(case_name) + r"\b", catalog)
    ]
    passed = bool(kernels) and not missing_shader and not missing_catalog
    detail = (
        "{} production kernels have MSL and Metal 4 access-catalog coverage".format(len(kernels))
        if passed
        else "missing shader={}, missing access-catalog names={}"
        .format(missing_shader, missing_catalog)
    )
    return AuditCheck("phase3.kernel-coverage", passed, True, detail)


def check_contracts(root: Path) -> AuditCheck:
    contracts = read(root / "Sources/NumiTissueMetal/Metal4ExecutionContracts.swift")
    policy = read(root / "Sources/NumiTissueMetal/Metal4ExecutionPolicy.swift")
    backend = read(root / "Sources/NumiTissueMetal/Metal4TissueBackend.swift")
    runtime = read(root / "Sources/NumiTissueMetal/Metal4CommandRuntime.swift")
    checkpoint = read(root / "Sources/NumiTissueMetal/Metal4CheckpointState.swift")
    required_fragments = [
        "maximumBufferBindingCount: Int = 31",
        "guard (1...31).contains(maximumBufferBindingCount)",
        "validatedForMetal4Backend()",
        "Metal4IndirectDispatchCatalog",
        "let configuration = try sourceConfiguration.validatedForMetal4Backend()",
    ]
    all_source = "\n".join([contracts, policy, backend, runtime, checkpoint])
    missing = [fragment for fragment in required_fragments if fragment not in all_source]
    stale = [
        token for token in (
            "indirectDispatchPolicy",
            "commandBufferSlotCount",
            "qualifiedIndirectKernels",
            "allocatedSize",
            "supportReport.reasons",
        ) if token in all_source
    ]
    passed = not missing and not stale
    detail = "ABI and backend policy contracts are internally aligned" if passed else (
        "missing contract fragments={} stale symbols={}".format(missing, stale)
    )
    return AuditCheck("phase3.contract-alignment", passed, True, detail)


def check_availability(root: Path) -> AuditCheck:
    failures = []
    for path in sorted((root / "Sources/NumiTissueMetal").glob("Metal4*.swift")):
        source = read(path)
        if "MTL4" in source and "compiler(>=6.2)" not in source:
            failures.append(str(path.relative_to(root)))
    support = read(root / "Sources/NumiTissueMetal/Metal4Support.swift")
    if "#if compiler(>=6.2)" not in support or "macOS 26.0" not in support:
        failures.append("Metal4Support.swift capability/availability guard")
    passed = not failures
    return AuditCheck(
        "phase3.availability",
        passed,
        True,
        "Metal 4 sources have compiler and OS availability guards"
        if passed else "unguarded Metal 4 surface: " + ", ".join(failures),
    )


def check_cli_surface(root: Path) -> AuditCheck:
    entrypoint = read(root / "Sources/NumiTissueCLI/CLIEntryPoint.swift")
    command = read(root / "Sources/NumiTissueCLI/Phase3Command.swift")
    required = [
        'case "phase3": try Phase3Command.run',
        'case "status":',
        'case "support":',
        'case "contract":',
        'case "verify":',
        "productionAuthorized",
        "promotionCertificate",
    ]
    missing = [fragment for fragment in required if fragment not in entrypoint + command]
    return AuditCheck(
        "phase3.cli-surface",
        not missing,
        True,
        "Phase 3 status, support, contract, and manifest verification commands are present"
        if not missing else "missing CLI fragments: " + ", ".join(missing),
    )


def check_git(root: Path) -> AuditCheck:
    try:
        dirty = run_git(root, "status", "--porcelain")
    except (OSError, subprocess.CalledProcessError) as error:
        return AuditCheck("phase3.git-state", False, True, str(error))
    return AuditCheck(
        "phase3.git-state",
        not dirty,
        True,
        "working tree is clean" if not dirty else "working tree is dirty",
    )


def check_python(root: Path) -> AuditCheck:
    scripts = sorted((root / "Tools").rglob("*.py"))
    try:
        for path in scripts:
            compile(read(path), str(path), "exec")
    except (OSError, SyntaxError, UnicodeError) as error:
        return AuditCheck("phase3.python-tools", False, True, str(error))
    return AuditCheck(
        "phase3.python-tools",
        True,
        True,
        "{} Phase 3 Python tools compile".format(len(scripts)),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    required_files = [
        "Tools/phase3/doctor.py",
        "Tools/phase3/run_apple_qualification.sh",
        "Tools/phase3/phase3_evidence.py",
        "Sources/NumiTissueCLI/Phase3Command.swift",
        "Docs/Verification/PHASE3.md",
        "Docs/Verification/PHASE3_STATUS.md",
        "Docs/Verification/PHASE3_REQUEST_SCHEMA.md",
        "Docs/Verification/PHASE3_THREAT_MODEL.md",
        ".github/workflows/phase3-metal4-qualification.yml",
    ]
    checks = [
        check_files(root, required_files),
        check_kernel_coverage(root),
        check_contracts(root),
        check_availability(root),
        check_cli_surface(root),
        check_python(root),
        check_git(root),
    ]
    try:
        revision = run_git(root, "rev-parse", "HEAD")
        source_digest = hashlib.sha256(
            "\n".join(
                read(path)
                for path in sorted((root / "Sources/NumiTissueMetal").glob("*.swift"))
            ).encode("utf-8")
        ).hexdigest()
    except (OSError, subprocess.CalledProcessError) as error:
        revision = None
        source_digest = None
        checks.append(AuditCheck("phase3.repository-identity", False, True, str(error)))

    report = {
        "schemaVersion": 1,
        "audit": "numitissue.phase3.source.v1",
        "passing": all(item.passed for item in checks if item.required),
        "repository": {
            "revision": revision,
            "sourceMetalSwiftSHA256": source_digest,
        },
        "host": {
            "system": platform.system(),
            "machine": platform.machine(),
            "python": sys.version,
        },
        "checks": [asdict(item) for item in checks],
    }
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 0 if report["passing"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
