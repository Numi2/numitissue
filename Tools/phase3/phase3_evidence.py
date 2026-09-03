#!/usr/bin/env python3
"""Create and verify bounded Phase 3 validation evidence.

The evidence produced here is an execution record, not a promotion
certificate.  Verification deliberately rejects production authorization,
portable credentials, unsafe paths, mismatched hashes, and incomplete
evidence graphs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable, Optional, Sequence


SCHEMA_VERSION = 1
MANIFEST_NAME = "manifest.json"
NON_EVIDENCE_OUTPUTS = {MANIFEST_NAME}
PROMOTION_REQUIRED_NODES = (
    "workload",
    "device",
    "execution-configuration",
    "pipeline-archive",
    "qualification-evidence",
    "qualification-bundle",
    "promotion-report",
    "promotion-certificate",
    "execution-identity",
    "checkpoint",
    "production-backend",
)


class EvidenceError(Exception):
    """A validation failure that must be surfaced to the caller."""


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError("cannot read JSON {}: {}".format(path, error))
    if not isinstance(value, dict):
        raise EvidenceError("{} must contain a JSON object".format(path))
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=str(path.parent),
            prefix=".phase3-",
            suffix=".tmp",
            delete=False,
        ) as handle:
            handle.write(encoded)
            temporary = Path(handle.name)
        os.replace(str(temporary), str(path))
    except OSError as error:
        try:
            if "temporary" in locals():
                temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise EvidenceError("cannot write {}: {}".format(path, error))


def safe_relative(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise EvidenceError("{} must be a nonempty relative path".format(field))
    if value.startswith(("/", "\\")) or "\\" in value:
        raise EvidenceError("{} is not a portable relative path".format(field))
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise EvidenceError("{} contains an unsafe path component".format(field))
    return value


def safe_child(root: Path, relative: str, field: str) -> Path:
    relative = safe_relative(relative, field)
    candidate = root.joinpath(*relative.split("/"))
    current = root
    for part in relative.split("/"):
        current = current / part
        if current.is_symlink():
            raise EvidenceError("{} traverses a symlink".format(field))
    return candidate


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as error:
        raise EvidenceError("cannot hash {}: {}".format(path, error))
    return digest.hexdigest()


def relative_to(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        raise EvidenceError("{} is outside {}".format(path, root))


def all_regular_files(root: Path) -> list[Path]:
    if not root.is_dir() or root.is_symlink():
        raise EvidenceError("evidence directory is not a real directory: {}".format(root))
    result: list[Path] = []
    for directory, directories, files in os.walk(str(root), followlinks=False):
        directory_path = Path(directory)
        for name in directories:
            if (directory_path / name).is_symlink():
                raise EvidenceError("evidence directory contains a symlink: {}".format(directory_path / name))
        for name in files:
            path = directory_path / name
            if path.is_symlink():
                raise EvidenceError("evidence directory contains a symlink: {}".format(path))
            if not path.is_file():
                raise EvidenceError("evidence entry is not a regular file: {}".format(path))
            result.append(path)
    return sorted(result)


def git_output(root: Path, *arguments: str) -> Optional[str]:
    try:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=str(root),
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def repository_identity(root: Path) -> dict[str, Any]:
    revision = git_output(root, "rev-parse", "HEAD")
    branch = git_output(root, "branch", "--show-current")
    origin_main = git_output(root, "rev-parse", "origin/main")
    status = git_output(root, "status", "--porcelain")
    return {
        "revision": revision,
        "branch": branch,
        "originMain": origin_main,
        "matchesOriginMain": revision is not None and revision == origin_main,
        "workingTreeClean": status == "",
        "remote": git_output(root, "config", "--get", "remote.origin.url"),
    }


def run_capture(arguments: Sequence[str], cwd: Path, environment: Optional[dict[str, str]] = None) -> tuple[int, str, str]:
    try:
        completed = subprocess.run(
            list(arguments),
            cwd=str(cwd),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        return 127, "", str(error)
    return completed.returncode, completed.stdout, completed.stderr


def command_record(
    output: Path,
    root: Path,
    identifier: str,
    arguments: Sequence[str],
    required: bool,
    environment_updates: Optional[dict[str, str]] = None,
) -> dict[str, Any]:
    log_relative = "logs/{}.log".format(identifier)
    log_path = safe_child(output, log_relative, "command log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    if environment_updates:
        environment.update(environment_updates)
    started = time.monotonic()
    start_time = now_utc()
    try:
        process = subprocess.Popen(
            list(arguments),
            cwd=str(root),
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        stdout, _ = process.communicate()
        exit_code = process.returncode
    except OSError as error:
        stdout = str(error)
        exit_code = 127
    duration = round(time.monotonic() - started, 3)
    header = {
        "startedAt": start_time,
        "durationSeconds": duration,
        "argv": list(arguments),
        "cwd": str(root),
        "environmentKeys": sorted(environment_updates or {}),
        "exitCode": exit_code,
    }
    log_path.write_text(
        json.dumps(header, indent=2, sort_keys=True)
        + "\n\n"
        + stdout,
        encoding="utf-8",
    )
    return {
        "id": identifier,
        "argv": list(arguments),
        "required": required,
        "success": exit_code == 0,
        "exitCode": exit_code,
        "durationSeconds": duration,
        "startedAt": start_time,
        "log": log_relative,
        "environmentKeys": sorted(environment_updates or {}),
    }


def artifact_records(output: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in all_regular_files(output):
        relative = relative_to(output, path)
        if relative in NON_EVIDENCE_OUTPUTS:
            continue
        records.append({
            "path": safe_relative(relative, "artifact path"),
            "byteCount": path.stat().st_size,
            "sha256": file_digest(path),
            "kind": "log" if relative.startswith("logs/") else "run-output",
        })
    return records


def graph_for_run(doctor_passed: bool, command_records: list[dict[str, Any]]) -> dict[str, Any]:
    required = set(PROMOTION_REQUIRED_NODES)
    statuses = {
        "workload": "not-bound",
        "device": "present" if doctor_passed else "unavailable",
        "execution-configuration": "not-bound",
        "pipeline-archive": "missing",
        "qualification-evidence": "present" if doctor_passed else "incomplete",
        "qualification-bundle": "missing",
        "promotion-report": "missing",
        "promotion-certificate": "missing",
        "execution-identity": "not-bound",
        "checkpoint": "not-retained",
        "production-backend": "not-authorized",
    }
    nodes = [
        {
            "id": identifier,
            "status": statuses[identifier],
            "requiredForPromotion": identifier in required,
        }
        for identifier in PROMOTION_REQUIRED_NODES
    ]
    edges = [
        {"from": "workload", "to": "execution-configuration"},
        {"from": "device", "to": "execution-configuration"},
        {"from": "execution-configuration", "to": "pipeline-archive"},
        {"from": "workload", "to": "qualification-evidence"},
        {"from": "device", "to": "qualification-evidence"},
        {"from": "pipeline-archive", "to": "qualification-evidence"},
        {"from": "qualification-evidence", "to": "qualification-bundle"},
        {"from": "qualification-bundle", "to": "promotion-report"},
        {"from": "promotion-report", "to": "promotion-certificate"},
        {"from": "execution-identity", "to": "checkpoint"},
        {"from": "promotion-certificate", "to": "production-backend"},
    ]
    return {
        "nodes": nodes,
        "edges": edges,
        "acyclic": True,
        "missingForProduction": [
            node["id"] for node in nodes if node["status"] not in ("present",)
        ],
    }


def make_manifest(
    output: Path,
    root: Path,
    audit: dict[str, Any],
    doctor: dict[str, Any],
    commands: list[dict[str, Any]],
) -> dict[str, Any]:
    doctor_passed = bool(doctor.get("passing"))
    required_failures = [
        record["id"]
        for record in commands
        if record.get("required") and not record.get("success")
    ]
    status = "hardware-smoke-only"
    if not doctor_passed:
        status = "failed-host-preflight"
    elif required_failures:
        status = "failed"
    repository = repository_identity(root)
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "numitissue.phase3.validation-run",
        "createdAt": now_utc(),
        "qualificationStatus": status,
        "executionPurpose": "qualification",
        "productionAuthorized": False,
        "promotionCertificate": None,
        "promotionBlockedReasons": [
            "this run is qualification evidence, not a sealed production authorization",
            "workload and execution configuration are not cryptographically bound",
            "pipeline archive evidence is not present",
            "sealed qualification bundle and promotion certificate are not present",
        ],
        "repository": repository,
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "python": sys.version,
        },
        "preflight": {
            "sourceAudit": {
                "path": "source-audit.json",
                "passing": bool(audit.get("passing")),
            },
            "appleSiliconDoctor": {
                "path": "doctor.json",
                "passing": doctor_passed,
            },
        },
        "commands": commands,
        "requiredCommandFailures": required_failures,
        "artifacts": artifact_records(output),
        "evidenceGraph": graph_for_run(doctor_passed, commands),
    }
    return manifest


def verify_graph(graph: Any) -> None:
    if not isinstance(graph, dict):
        raise EvidenceError("evidenceGraph must be an object")
    nodes = graph.get("nodes")
    edges = graph.get("edges")
    if not isinstance(nodes, list) or not isinstance(edges, list):
        raise EvidenceError("evidenceGraph nodes and edges are required arrays")
    identifiers: set[str] = set()
    statuses: dict[str, str] = {}
    for node in nodes:
        if not isinstance(node, dict):
            raise EvidenceError("evidenceGraph contains a non-object node")
        identifier = node.get("id")
        status = node.get("status")
        if not isinstance(identifier, str) or not identifier or identifier in identifiers:
            raise EvidenceError("evidenceGraph contains a duplicate or invalid node id")
        if not isinstance(status, str) or not status:
            raise EvidenceError("evidenceGraph node {} has no status".format(identifier))
        identifiers.add(identifier)
        statuses[identifier] = status
    indegree = {identifier: 0 for identifier in identifiers}
    adjacency: dict[str, list[str]] = {identifier: [] for identifier in identifiers}
    seen_edges: set[tuple[str, str]] = set()
    for edge in edges:
        if not isinstance(edge, dict):
            raise EvidenceError("evidenceGraph contains a non-object edge")
        source = edge.get("from")
        target = edge.get("to")
        if not isinstance(source, str) or not isinstance(target, str):
            raise EvidenceError("evidenceGraph edge endpoints must be strings")
        if source == target or source not in identifiers or target not in identifiers:
            raise EvidenceError("evidenceGraph contains an invalid or self edge")
        if (source, target) in seen_edges:
            raise EvidenceError("evidenceGraph contains a duplicate edge")
        seen_edges.add((source, target))
        adjacency[source].append(target)
        indegree[target] += 1
    queue = [identifier for identifier, degree in indegree.items() if degree == 0]
    visited = 0
    while queue:
        source = queue.pop()
        visited += 1
        for target in adjacency[source]:
            indegree[target] -= 1
            if indegree[target] == 0:
                queue.append(target)
    if visited != len(identifiers):
        raise EvidenceError("evidenceGraph contains a cycle")
    missing = graph.get("missingForProduction")
    if not isinstance(missing, list) or any(not isinstance(item, str) for item in missing):
        raise EvidenceError("evidenceGraph missingForProduction is invalid")
    for identifier in PROMOTION_REQUIRED_NODES:
        if identifier not in identifiers:
            raise EvidenceError("evidenceGraph omits promotion node {}".format(identifier))
        if statuses[identifier] != "present" and identifier not in missing:
            raise EvidenceError("evidenceGraph omits missing promotion node {}".format(identifier))


def verify_manifest(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise EvidenceError("manifest must not be a symlink")
    manifest = load_json(path)
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise EvidenceError("unsupported manifest schema")
    if manifest.get("kind") != "numitissue.phase3.validation-run":
        raise EvidenceError("unexpected manifest kind")
    if manifest.get("executionPurpose") != "qualification":
        raise EvidenceError("only qualification execution records are accepted")
    if manifest.get("productionAuthorized") is not False:
        raise EvidenceError("production authorization is not verifiable by this manifest verifier")
    if manifest.get("promotionCertificate") is not None:
        raise EvidenceError("detached or embedded promotion certificates are rejected")
    repository = manifest.get("repository")
    if not isinstance(repository, dict):
        raise EvidenceError("repository identity is required")
    revision = repository.get("revision")
    if not isinstance(revision, str) or len(revision) != 40 or any(
        character not in "0123456789abcdef" for character in revision.lower()
    ):
        raise EvidenceError("repository revision is not a full hexadecimal commit")

    root = path.resolve().parent
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise EvidenceError("artifacts must be an array")
    artifact_paths: set[str] = set()
    for record in artifacts:
        if not isinstance(record, dict):
            raise EvidenceError("artifact record is not an object")
        relative = safe_relative(record.get("path"), "artifact path")
        if relative in artifact_paths or relative == MANIFEST_NAME:
            raise EvidenceError("duplicate or self-referential artifact path {}".format(relative))
        artifact_paths.add(relative)
        actual_path = safe_child(root, relative, "artifact path")
        if not actual_path.is_file() or actual_path.is_symlink():
            raise EvidenceError("artifact is missing or not a regular file: {}".format(relative))
        expected_size = record.get("byteCount")
        expected_digest = record.get("sha256")
        if not isinstance(expected_size, int) or expected_size < 0:
            raise EvidenceError("artifact {} has an invalid byteCount".format(relative))
        if not isinstance(expected_digest, str) or len(expected_digest) != 64:
            raise EvidenceError("artifact {} has an invalid sha256".format(relative))
        if actual_path.stat().st_size != expected_size:
            raise EvidenceError("artifact size mismatch: {}".format(relative))
        if file_digest(actual_path) != expected_digest.lower():
            raise EvidenceError("artifact digest mismatch: {}".format(relative))

    actual_files = {
        relative_to(root, candidate)
        for candidate in all_regular_files(root)
        if relative_to(root, candidate) not in NON_EVIDENCE_OUTPUTS
    }
    if actual_files != artifact_paths:
        raise EvidenceError(
            "artifact inventory mismatch; unrecorded={}, missing={}".format(
                sorted(actual_files - artifact_paths),
                sorted(artifact_paths - actual_files),
            )
        )

    preflight = manifest.get("preflight")
    if not isinstance(preflight, dict):
        raise EvidenceError("preflight record is required")
    for key in ("sourceAudit", "appleSiliconDoctor"):
        record = preflight.get(key)
        if not isinstance(record, dict):
            raise EvidenceError("preflight {} is missing".format(key))
        safe_relative(record.get("path"), "preflight path")
        if record["path"] not in artifact_paths:
            raise EvidenceError("preflight {} is not recorded as an artifact".format(key))
        if not isinstance(record.get("passing"), bool):
            raise EvidenceError("preflight {} passing value is invalid".format(key))

    commands = manifest.get("commands")
    if not isinstance(commands, list):
        raise EvidenceError("commands must be an array")
    command_ids: set[str] = set()
    for record in commands:
        if not isinstance(record, dict):
            raise EvidenceError("command record is not an object")
        identifier = record.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in command_ids:
            raise EvidenceError("command id is duplicate or invalid")
        command_ids.add(identifier)
        if not isinstance(record.get("required"), bool):
            raise EvidenceError("command {} required value is invalid".format(identifier))
        if not isinstance(record.get("success"), bool):
            raise EvidenceError("command {} success value is invalid".format(identifier))
        if not isinstance(record.get("exitCode"), int):
            raise EvidenceError("command {} exitCode is invalid".format(identifier))
        log = safe_relative(record.get("log"), "command log")
        if log not in artifact_paths:
            raise EvidenceError("command {} log is not recorded".format(identifier))
    required_failures = manifest.get("requiredCommandFailures")
    expected_failures = sorted(
        record["id"] for record in commands if record["required"] and not record["success"]
    )
    if required_failures != expected_failures:
        raise EvidenceError("requiredCommandFailures does not match command records")

    verify_graph(manifest.get("evidenceGraph"))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "manifest": str(path),
        "valid": True,
        "qualificationStatus": manifest.get("qualificationStatus"),
        "productionAuthorized": False,
        "verifiedArtifactCount": len(artifacts),
        "promotionEligible": False,
        "reason": "manifest is an integrity-checked qualification record; promotion remains blocked",
    }


def phase3_status(manifest: Optional[Path]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "component": "numitissue.phase3",
        "sourceAudit": "required-before-execution",
        "hardwareQualification": "not-run",
        "productionAuthorized": False,
        "promotion": "blocked-until-bound-certificate-and-evidence-graph-are-verified",
        "supportedEvidenceCommands": ["manifest", "run", "status", "verify"],
    }
    if manifest is not None:
        result["manifest"] = verify_manifest(manifest)
    return result


def output_directory(path: Path) -> Path:
    path = path.expanduser().resolve()
    if path.exists():
        if path.is_symlink() or not path.is_dir():
            raise EvidenceError("output must be a real directory or a new path")
        if any(path.iterdir()):
            raise EvidenceError("refusing to overwrite nonempty evidence directory: {}".format(path))
    else:
        path.mkdir(parents=True, exist_ok=False)
    return path


def run_qualification(root: Path, output: Path) -> int:
    root = root.expanduser().resolve()
    if not (root / ".git").exists():
        raise EvidenceError("root is not a Git checkout: {}".format(root))
    output = output.expanduser().resolve()

    # The source audit must observe the pristine checkout before any output is
    # created.  Output is normally ignored by Git, but the ordering makes a
    # dirty-run claim impossible even when a caller chooses another directory.
    audit_code, audit_stdout, audit_stderr = run_capture(
        [sys.executable, str(root / "Tools/phase3/static_audit.py"), "--root", str(root)],
        root,
    )
    if audit_code != 0:
        sys.stderr.write(audit_stdout + audit_stderr)
        raise EvidenceError("Phase 3 source audit failed before evidence directory creation")
    try:
        audit = json.loads(audit_stdout)
    except json.JSONDecodeError as error:
        raise EvidenceError("source audit did not return JSON: {}".format(error))
    if not isinstance(audit, dict) or audit.get("passing") is not True:
        raise EvidenceError("Phase 3 source audit did not pass")

    output = output_directory(output)
    write_json(output / "source-audit.json", audit)

    doctor_code, doctor_stdout, doctor_stderr = run_capture(
        [sys.executable, str(root / "Tools/phase3/doctor.py")],
        root,
    )
    try:
        doctor = json.loads(doctor_stdout)
    except json.JSONDecodeError as error:
        raise EvidenceError("Apple-Silicon doctor did not return JSON: {}".format(error))
    write_json(output / "doctor.json", doctor)

    commands: list[dict[str, Any]] = []
    if doctor_code == 0 and doctor.get("passing") is True:
        python_compile = (
            "from pathlib import Path; "
            "paths=sorted(Path('Tools').rglob('*.py')); "
            "[compile(p.read_text(encoding='utf-8'), str(p), 'exec') for p in paths]; "
            "print('compiled', len(paths), 'Python tools without generating bytecode')"
        )
        commands.append(command_record(
            output,
            root,
            "python-tools-syntax",
            [sys.executable, "-c", python_compile],
            True,
        ))
        commands.append(command_record(
            output,
            root,
            "swift-build-strict",
            ["swift", "build", "-Xswiftc", "-warnings-as-errors"],
            True,
        ))
        commands.append(command_record(
            output,
            root,
            "swift-tests-metal-debug",
            ["swift", "test", "--parallel", "-Xswiftc", "-warnings-as-errors"],
            True,
            {"MTL_DEBUG_LAYER": "1", "NUMITISSUE_RUN_METAL_DIFFERENTIAL": "1"},
        ))
        commands.append(command_record(
            output,
            root,
            "swift-tests-release-metal4",
            [
                "swift", "test", "-c", "release", "--filter",
                "Metal4PlanningValidationTests", "-Xswiftc", "-warnings-as-errors",
            ],
            True,
            {"MTL_DEBUG_LAYER": "1", "NUMITISSUE_RUN_METAL_DIFFERENTIAL": "1"},
        ))
        commands.append(command_record(
            output,
            root,
            "swift-tests-address-sanitizer-metal4",
            [
                "swift", "test", "--sanitize=address", "--filter",
                "Metal4PlanningValidationTests", "-Xswiftc", "-warnings-as-errors",
            ],
            True,
            {"MTL_DEBUG_LAYER": "1", "NUMITISSUE_RUN_METAL_DIFFERENTIAL": "1"},
        ))
        commands.append(command_record(
            output,
            root,
            "swift-tests-thread-sanitizer-metal4",
            [
                "swift", "test", "--sanitize=thread", "--filter",
                "Metal4PlanningValidationTests", "-Xswiftc", "-warnings-as-errors",
            ],
            True,
            {"MTL_DEBUG_LAYER": "1", "NUMITISSUE_RUN_METAL_DIFFERENTIAL": "1"},
        ))
        commands.append(command_record(
            output,
            root,
            "metal-shader-library-prewarm",
            [
                "swift", "test", "--filter", "MetalExecutionValidationTests",
                "-Xswiftc", "-warnings-as-errors",
            ],
            True,
            {"MTL_DEBUG_LAYER": "1"},
        ))
        for name in ("NumiTissueMechanismVM", "NumiTissueMechanismVM2", "NumiTissueMolecularVM"):
            source = "Sources/NumiTissueMetal/Shaders/{}.metal".format(name)
            air = output / "metal" / (name + ".air")
            metallib = output / "metal" / (name + ".metallib")
            air.parent.mkdir(parents=True, exist_ok=True)
            commands.append(command_record(
                output,
                root,
                "metal-compile-{}".format(name.lower()),
                ["xcrun", "metal", "-c", source, "-o", str(air)],
                True,
            ))
            commands.append(command_record(
                output,
                root,
                "metal-link-{}".format(name.lower()),
                ["xcrun", "metallib", str(air), "-o", str(metallib)],
                True,
            ))
        commands.append(command_record(
            output,
            root,
            "cli-help",
            [".build/debug/numitissue", "--help"],
            True,
        ))
        commands.append(command_record(
            output,
            root,
            "cli-version",
            [".build/debug/numitissue", "version"],
            True,
        ))
        commands.append(command_record(
            output,
            root,
            "cli-phase2-contract",
            [".build/debug/numitissue", "phase2", "contract", "scientific32"],
            True,
        ))
        commands.append(command_record(
            output,
            root,
            "cli-phase3-status",
            [".build/debug/numitissue", "phase3", "status"],
            True,
        ))
        commands.append(command_record(
            output,
            root,
            "cli-phase3-support",
            [".build/debug/numitissue", "phase3", "support"],
            True,
        ))
        commands.append(command_record(
            output,
            root,
            "phase3-python-status",
            [sys.executable, "Tools/phase3/phase3_evidence.py", "status"],
            True,
        ))
    else:
        commands.append({
            "id": "apple-silicon-doctor",
            "argv": [sys.executable, str(root / "Tools/phase3/doctor.py")],
            "required": True,
            "success": False,
            "exitCode": doctor_code,
            "durationSeconds": 0,
            "startedAt": now_utc(),
            "log": "logs/apple-silicon-doctor.log",
            "environmentKeys": [],
        })
        log_path = safe_child(output, "logs/apple-silicon-doctor.log", "doctor log")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(doctor_stdout + doctor_stderr, encoding="utf-8")

    # The pinned reference environment is informative for this hardware run.
    # A missing external NEURON/Arbor/STEPS installation is retained as a
    # non-required result and never converted into a passing qualification.
    commands.append(command_record(
        output,
        root,
        "reference-environment-doctor",
        [
            sys.executable,
            "Tools/validation/doctor.py",
            "--output",
            str(output / "reference-environment.json"),
        ],
        False,
    ))

    manifest_path = output / MANIFEST_NAME
    # Create a provisional manifest so the shipped Swift verifier is exercised
    # against the same path that the final record will expose. The verifier's
    # log is then added to the final manifest inventory in a second pass.
    provisional = make_manifest(output, root, audit, doctor, commands)
    write_json(manifest_path, provisional)
    commands.append(command_record(
        output,
        root,
        "cli-phase3-verify",
        [".build/debug/numitissue", "phase3", "verify", str(manifest_path)],
        True,
    ))
    manifest = make_manifest(output, root, audit, doctor, commands)
    write_json(manifest_path, manifest)
    verification = verify_manifest(manifest_path)
    sys.stdout.write(json.dumps(verification, indent=2, sort_keys=True) + "\n")
    required_failures = manifest["requiredCommandFailures"]
    if doctor_code != 0 or doctor.get("passing") is not True or required_failures:
        return 2
    return 0


def build_manifest_from_directory(arguments: argparse.Namespace) -> int:
    output = arguments.directory.expanduser().resolve()
    if not output.is_dir():
        raise EvidenceError("evidence directory does not exist: {}".format(output))
    audit_path = arguments.audit or (output / "source-audit.json")
    doctor_path = arguments.doctor or (output / "doctor.json")
    audit = load_json(audit_path)
    doctor = load_json(doctor_path)
    commands: list[dict[str, Any]] = []
    if arguments.commands:
        value = load_json(arguments.commands)
        source = value.get("commands") if isinstance(value, dict) else value
        if not isinstance(source, list):
            raise EvidenceError("commands input must be a JSON array or object with commands")
        commands = source
    manifest = make_manifest(output, arguments.root.expanduser().resolve(), audit, doctor, commands)
    path = arguments.output or (output / MANIFEST_NAME)
    if path.resolve().parent != output:
        raise EvidenceError("manifest output must be inside the evidence directory")
    write_json(path, manifest)
    result = verify_manifest(path)
    sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--manifest", type=Path)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("manifest", type=Path)

    manifest_parser = subparsers.add_parser("manifest")
    manifest_parser.add_argument("--directory", type=Path, required=True)
    manifest_parser.add_argument("--root", type=Path, required=True)
    manifest_parser.add_argument("--audit", type=Path)
    manifest_parser.add_argument("--doctor", type=Path)
    manifest_parser.add_argument("--commands", type=Path)
    manifest_parser.add_argument("--output", type=Path)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--root", type=Path, required=True)
    run_parser.add_argument("--output", type=Path, required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "status":
            result = phase3_status(arguments.manifest)
            sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
            return 0
        if arguments.command == "verify":
            result = verify_manifest(arguments.manifest.expanduser().resolve())
            sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
            return 0
        if arguments.command == "manifest":
            return build_manifest_from_directory(arguments)
        if arguments.command == "run":
            return run_qualification(arguments.root, arguments.output)
        raise EvidenceError("unknown command")
    except EvidenceError as error:
        failure = {
            "schemaVersion": SCHEMA_VERSION,
            "valid": False,
            "productionAuthorized": False,
            "error": str(error),
        }
        sys.stderr.write(json.dumps(failure, indent=2, sort_keys=True) + "\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
