#!/usr/bin/env python3
"""Fail-closed Apple-Silicon and Metal 4 preflight for Phase 3.

The doctor only establishes that the host can attempt the controlled run.  It
does not qualify numerical results and it cannot issue a production
certificate.
"""

from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Optional, Tuple


@dataclass(frozen=True)
class DoctorCheck:
    identifier: str
    passed: bool
    required: bool
    detail: str
    observed: Optional[str] = None


def command(arguments: Iterable[str]) -> Tuple[int, str, str]:
    try:
        completed = subprocess.run(
            list(arguments),
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        return 127, "", str(error)
    return completed.returncode, completed.stdout.strip(), completed.stderr.strip()


def version_tuple(value: str) -> Tuple[int, ...]:
    match = re.search(r"(\d+(?:\.\d+)*)", value)
    if not match:
        return tuple()
    return tuple(int(part) for part in match.group(1).split("."))


def at_least(value: str, minimum: Tuple[int, ...]) -> bool:
    parsed = version_tuple(value)
    width = max(len(parsed), len(minimum))
    return (parsed + (0,) * (width - len(parsed))) >= (
        minimum + (0,) * (width - len(minimum))
    )


def check_command(identifier: str, arguments: Iterable[str]) -> DoctorCheck:
    code, stdout, stderr = command(arguments)
    observed = stdout or stderr or None
    return DoctorCheck(
        identifier=identifier,
        passed=code == 0 and bool(stdout),
        required=True,
        detail="command completed" if code == 0 else "command failed",
        observed=observed,
    )


def locate_tool(identifier: str, tool: str) -> DoctorCheck:
    path = shutil.which(tool)
    return DoctorCheck(
        identifier=identifier,
        passed=path is not None,
        required=True,
        detail="tool available" if path else "tool is not available on PATH",
        observed=path,
    )


def locate_xcrun_tool(identifier: str, tool: str) -> DoctorCheck:
    code, stdout, stderr = command(["xcrun", "--find", tool])
    return DoctorCheck(
        identifier=identifier,
        passed=code == 0 and bool(stdout),
        required=True,
        detail="xcrun tool available" if code == 0 and stdout else "xcrun tool is unavailable",
        observed=stdout or stderr or None,
    )


def metal_headers(sdk_path: Path) -> Optional[Path]:
    candidates = [
        sdk_path / "System/Library/Frameworks/Metal.framework/Versions/A/Headers",
        sdk_path / "System/Library/Frameworks/Metal.framework/Headers",
    ]
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    return None


def header_surface_check(headers: Optional[Path]) -> DoctorCheck:
    if headers is None:
        return DoctorCheck(
            "metal4.sdk-header-surface",
            False,
            True,
            "Metal.framework headers were not found in the selected SDK",
        )

    files = {
        "MTLDevice.h",
        "MTL4ArgumentTable.h",
        "MTL4CommandAllocator.h",
        "MTL4CommandBuffer.h",
        "MTL4CommandQueue.h",
        "MTL4CommandEncoder.h",
        "MTL4ComputeCommandEncoder.h",
        "MTL4CommitFeedback.h",
        "MTLResidencySet.h",
    }
    missing_files = sorted(name for name in files if not (headers / name).is_file())
    if missing_files:
        return DoctorCheck(
            "metal4.sdk-header-surface",
            False,
            True,
            "required Metal headers are missing",
            ", ".join(missing_files),
        )

    contents = {
        name: (headers / name).read_text(encoding="utf-8", errors="replace")
        for name in files
    }
    required_types = {
        "MTLDevice.h": [
            "MTL4ArgumentTable",
            "MTL4ArgumentTableDescriptor",
            "MTL4CommandAllocator",
            "MTL4CommandBuffer",
            "MTL4CommandQueue",
        ],
        "MTL4CommandBuffer.h": ["MTL4CommandBuffer", "MTL4ComputeCommandEncoder"],
        "MTL4CommandEncoder.h": ["MTL4CommandEncoder"],
        "MTL4CommandQueue.h": ["MTL4CommandQueue"],
        "MTL4ComputeCommandEncoder.h": ["MTL4ComputeCommandEncoder"],
        "MTLResidencySet.h": ["MTLResidencySet"],
    }
    required_members = {
        "MTLDevice.h": [
            "newCommandAllocator",
            "newCommandBuffer",
            "newArgumentTableWithDescriptor",
            "newMTL4CommandQueue",
        ],
        "MTL4ArgumentTable.h": ["maxBufferBindCount", "setAddress"],
        "MTL4CommandAllocator.h": ["reset"],
        "MTL4CommandBuffer.h": [
            "beginCommandBufferWithAllocator",
            "computeCommandEncoder",
            "endCommandBuffer",
            "useResidencySet",
        ],
        "MTL4CommandEncoder.h": ["barrierAfterEncoderStages", "endEncoding"],
        "MTL4CommandQueue.h": [
            "commit:count:options:",
            "addResidencySets",
            "removeResidencySets",
        ],
        "MTL4ComputeCommandEncoder.h": [
            "setArgumentTable",
            "dispatchThreads",
            "dispatchThreadgroupsWithIndirectBuffer",
        ],
        "MTLResidencySet.h": [
            "addAllocations",
            "commit",
            "requestResidency",
        ],
    }
    missing: list[str] = []
    for filename, names in required_types.items():
        text = contents.get(filename, "")
        missing.extend(
            "{}:{}".format(filename, name)
            for name in names
            if not re.search(r"\b" + re.escape(name) + r"\b", text)
        )
    for filename, names in required_members.items():
        text = contents.get(filename, "")
        missing.extend(
            "{}:{}".format(filename, name)
            for name in names
            if name not in text
        )
    return DoctorCheck(
        "metal4.sdk-header-surface",
        not missing,
        True,
        "the exact Metal 4 types and selectors used by NumiTissue are present"
        if not missing
        else "missing Metal 4 SDK surface",
        ", ".join(missing) if missing else str(headers),
    )


def gpu_check() -> DoctorCheck:
    code, stdout, stderr = command(["system_profiler", "SPDisplaysDataType", "-json"])
    if code != 0:
        return DoctorCheck(
            "metal4.device-family",
            False,
            True,
            "system_profiler could not inspect the display GPU",
            stderr or None,
        )
    try:
        value: Any = json.loads(stdout)
    except json.JSONDecodeError as error:
        return DoctorCheck(
            "metal4.device-family",
            False,
            True,
            "system_profiler returned invalid JSON",
            str(error),
        )
    displays = value.get("SPDisplaysDataType", []) if isinstance(value, dict) else []
    metal4 = []
    names = []
    if isinstance(displays, list):
        for display in displays:
            if not isinstance(display, dict):
                continue
            name = display.get("_name") or display.get("sppci_model")
            if name:
                names.append(str(name))
            if str(display.get("spdisplays_mtlgpufamilysupport", "")).lower() == "spdisplays_metal4":
                metal4.append(str(name or "unknown"))
    return DoctorCheck(
        "metal4.device-family",
        bool(metal4),
        True,
        "at least one GPU advertises Metal 4"
        if metal4
        else "no GPU advertises Metal 4",
        "; ".join(metal4 or names) or None,
    )


def run_doctor() -> dict[str, Any]:
    checks: list[DoctorCheck] = []
    system = platform.system()
    machine = platform.machine()
    checks.append(DoctorCheck(
        "host.darwin",
        system == "Darwin",
        True,
        "Darwin host detected" if system == "Darwin" else "Phase 3 requires Darwin",
        system,
    ))
    checks.append(DoctorCheck(
        "host.arm64",
        machine in ("arm64", "aarch64"),
        True,
        "Apple Silicon architecture detected"
        if machine in ("arm64", "aarch64")
        else "Phase 3 requires arm64 Apple Silicon",
        machine,
    ))

    code, os_version, stderr = command(["sw_vers", "-productVersion"])
    if code != 0:
        os_version = platform.mac_ver()[0]
    checks.append(DoctorCheck(
        "host.macos",
        bool(os_version) and at_least(os_version, (26, 0)),
        True,
        "macOS 26 or newer detected"
        if os_version and at_least(os_version, (26, 0))
        else "Metal 4 execution requires macOS 26 or newer",
        os_version or stderr or None,
    ))

    code, xcode, stderr = command(["xcodebuild", "-version"])
    xcode_version = xcode or stderr
    checks.append(DoctorCheck(
        "toolchain.xcode",
        code == 0 and at_least(xcode_version, (26, 0)),
        True,
        "Xcode 26 or newer detected"
        if code == 0 and at_least(xcode_version, (26, 0))
        else "Xcode 26 or newer is required",
        xcode_version or None,
    ))
    checks.append(locate_tool("toolchain.swift", "swift"))
    swift_code, swift_version, swift_stderr = command(["swift", "--version"])
    checks.append(DoctorCheck(
        "toolchain.swift-version",
        swift_code == 0 and re.search(r"(?:Apple )?Swift version 6\.", swift_version) is not None,
        True,
        "Swift 6 toolchain detected"
        if swift_code == 0 and re.search(r"(?:Apple )?Swift version 6\.", swift_version)
        else "Swift 6 is required",
        swift_version or swift_stderr or None,
    ))
    checks.append(locate_xcrun_tool("toolchain.metal", "metal"))
    checks.append(locate_xcrun_tool("toolchain.metallib", "metallib"))

    code, sdk_version, stderr = command(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    checks.append(DoctorCheck(
        "toolchain.metal-sdk",
        code == 0 and at_least(sdk_version, (26, 0)),
        True,
        "macOS 26 SDK detected"
        if code == 0 and at_least(sdk_version, (26, 0))
        else "a macOS 26 or newer SDK is required",
        sdk_version or stderr or None,
    ))
    code, sdk_path_value, stderr = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    sdk_path = Path(sdk_path_value) if code == 0 and sdk_path_value else None
    checks.append(DoctorCheck(
        "toolchain.sdk-path",
        sdk_path is not None and sdk_path.is_dir(),
        True,
        "selected SDK path exists" if sdk_path and sdk_path.is_dir() else "selected SDK path is unavailable",
        str(sdk_path) if sdk_path else stderr or None,
    ))
    checks.append(header_surface_check(metal_headers(sdk_path) if sdk_path else None))
    checks.append(gpu_check())

    passing = all(check.passed for check in checks if check.required)
    return {
        "schemaVersion": 1,
        "doctor": "numitissue.phase3.apple-silicon.v1",
        "passing": passing,
        "productionAuthorized": False,
        "host": {
            "system": system,
            "machine": machine,
            "python": sys.version,
        },
        "checks": [asdict(check) for check in checks],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    report = run_doctor()
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 0 if report["passing"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
