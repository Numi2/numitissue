#!/usr/bin/env python3
"""Shared, dependency-free safety and provenance utilities for Phase 4 sidecars."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import math
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

SCHEMA_VERSION = 1
CHUNK_BYTES = 4 * 1024 * 1024


class SidecarFailure(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class LoadedRequest:
    value: dict[str, Any]
    canonical_bytes: bytes
    sha256: str


@dataclass(frozen=True)
class VerifiedInput:
    identifier: str
    path: Path
    media_type: str
    role: str
    byte_count: int
    sha256: str
    metadata: dict[str, str]


def canonical_json_bytes(value: Any) -> bytes:
    normalized = finite_json(value)
    return json.dumps(
        normalized,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def read_json(path: Path, maximum_bytes: int = 64 * 1024 * 1024) -> Any:
    try:
        size = path.stat().st_size
    except OSError as error:
        raise SidecarFailure("input.stat", f"Unable to stat {path}: {error}") from error
    if size <= 0 or size > maximum_bytes:
        raise SidecarFailure(
            "input.size",
            f"JSON input {path} has {size} bytes; allowed range is 1...{maximum_bytes}.",
        )
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SidecarFailure("input.json", f"Unable to decode {path}: {error}") from error


def load_request(
    path: Path,
    expected_sidecar: str,
    allowed_operations: set[str],
) -> LoadedRequest:
    value = read_json(path)
    if not isinstance(value, dict):
        raise SidecarFailure("request.type", "Sidecar request must be a JSON object.")
    if value.get("schemaVersion") != SCHEMA_VERSION:
        raise SidecarFailure("request.schema", "Unsupported sidecar request schemaVersion.")
    request_id = value.get("requestID")
    if not isinstance(request_id, str) or not request_id:
        raise SidecarFailure("request.id", "Sidecar requestID must be nonempty.")
    if value.get("sidecar") != expected_sidecar:
        raise SidecarFailure(
            "request.sidecar",
            f"Expected sidecar '{expected_sidecar}', received {value.get('sidecar')!r}.",
        )
    operation = value.get("operation")
    if operation not in allowed_operations:
        raise SidecarFailure(
            "request.operation",
            f"Operation {operation!r} is not supported by {expected_sidecar}.",
        )
    toolchain = value.get("toolchain")
    if not isinstance(toolchain, dict) or toolchain.get("sidecar") != expected_sidecar:
        raise SidecarFailure("request.toolchain", "Toolchain sidecar does not match request.")
    inputs = value.get("inputs")
    if not isinstance(inputs, list) or not inputs:
        raise SidecarFailure("request.inputs", "At least one input is required.")
    identifiers = [item.get("id") for item in inputs if isinstance(item, dict)]
    if len(identifiers) != len(inputs) or any(not isinstance(item, str) or not item for item in identifiers):
        raise SidecarFailure("request.inputs", "Every input requires a nonempty id.")
    if len(set(identifiers)) != len(identifiers):
        raise SidecarFailure("request.inputs", "Input ids must be unique.")
    validate_selection(value.get("selection"))
    canonical = canonical_json_bytes(value)
    return LoadedRequest(value=value, canonical_bytes=canonical, sha256=sha256_bytes(canonical))


def validate_selection(value: Any) -> None:
    if not isinstance(value, dict):
        raise SidecarFailure("selection.type", "selection must be a JSON object.")
    maximum_records = require_bounded_int(value, "maximumRecords", 1, 100_000_000)
    maximum_samples = require_bounded_int(
        value, "maximumSamplesPerSeries", 1, 1_000_000_000
    )
    maximum_output = require_bounded_int(
        value, "maximumOutputBytes", 1, 1_099_511_627_776
    )
    del maximum_records, maximum_samples, maximum_output
    start = optional_finite_number(value.get("startTimeSeconds"), "startTimeSeconds")
    end = optional_finite_number(value.get("endTimeSeconds"), "endTimeSeconds")
    if start is not None and start < 0:
        raise SidecarFailure("selection.time", "startTimeSeconds cannot be negative.")
    if end is not None and end < 0:
        raise SidecarFailure("selection.time", "endTimeSeconds cannot be negative.")
    if start is not None and end is not None and end < start:
        raise SidecarFailure("selection.time", "endTimeSeconds precedes startTimeSeconds.")
    for key in ("objectPaths", "subjectIDs", "electrodeIDs", "featureNames"):
        items = value.get(key, [])
        if not isinstance(items, list) or any(not isinstance(item, str) or not item for item in items):
            raise SidecarFailure("selection.list", f"{key} must be an array of nonempty strings.")
        if len(set(items)) != len(items):
            raise SidecarFailure("selection.list", f"{key} contains duplicate values.")


def require_bounded_int(value: Mapping[str, Any], key: str, lower: int, upper: int) -> int:
    item = value.get(key)
    if isinstance(item, bool) or not isinstance(item, int) or not lower <= item <= upper:
        raise SidecarFailure(
            "selection.bound",
            f"{key} must be an integer in {lower}...{upper}.",
        )
    return item


def optional_finite_number(value: Any, name: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SidecarFailure("number.type", f"{name} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise SidecarFailure("number.finite", f"{name} must be finite.")
    return result


def verify_toolchain(
    request: LoadedRequest,
    *,
    implementation: str,
    implementation_version: str,
    packages: Mapping[str, str],
) -> dict[str, str]:
    toolchain = request.value["toolchain"]
    if toolchain.get("implementation") != implementation:
        raise SidecarFailure(
            "toolchain.implementation",
            f"Request requires {toolchain.get('implementation')!r}; this executable is {implementation!r}.",
        )
    if toolchain.get("implementationVersion") != implementation_version:
        raise SidecarFailure(
            "toolchain.version",
            f"Request requires sidecar version {toolchain.get('implementationVersion')!r}; available version is {implementation_version!r}.",
        )
    requested_packages = toolchain.get("packageVersions", {})
    if not isinstance(requested_packages, dict):
        raise SidecarFailure("toolchain.packages", "packageVersions must be a JSON object.")
    actual: dict[str, str] = {}
    for name, expected in packages.items():
        if requested_packages.get(name) != expected:
            raise SidecarFailure(
                "toolchain.package-pin",
                f"Request must pin {name}=={expected}.",
            )
        try:
            found = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError as error:
            raise SidecarFailure(
                "toolchain.package-missing", f"Required package {name}=={expected} is not installed."
            ) from error
        if found != expected:
            raise SidecarFailure(
                "toolchain.package-version",
                f"Required package {name}=={expected}; installed version is {found}.",
            )
        actual[name] = found
    return actual


def verify_inputs(
    request: LoadedRequest,
    input_root: Path,
    maximum_total_bytes: int = 4 * 1024 * 1024 * 1024 * 1024,
) -> list[VerifiedInput]:
    root = input_root.expanduser().resolve(strict=True)
    if not root.is_dir():
        raise SidecarFailure("input.root", f"Input root is not a directory: {root}")
    verified: list[VerifiedInput] = []
    total = 0
    for value in request.value["inputs"]:
        if not isinstance(value, dict):
            raise SidecarFailure("input.type", "Each input must be a JSON object.")
        relative = value.get("relativePath")
        if not isinstance(relative, str) or not safe_relative_path(relative):
            raise SidecarFailure("input.path", f"Unsafe relative input path: {relative!r}")
        path = resolve_under(root, relative, must_exist=True)
        if not path.is_file():
            raise SidecarFailure("input.file", f"Input is not a regular file: {relative}")
        digest, byte_count = sha256_file(path)
        expected_digest = value.get("sha256")
        if not isinstance(expected_digest, str) or digest != expected_digest.lower():
            raise SidecarFailure(
                "input.sha256",
                f"SHA-256 mismatch for input {value.get('id')!r}: expected {expected_digest!r}, actual {digest}.",
            )
        expected_bytes = value.get("byteCount")
        if expected_bytes is not None and expected_bytes != byte_count:
            raise SidecarFailure(
                "input.byte-count",
                f"Byte-count mismatch for input {value.get('id')!r}: expected {expected_bytes}, actual {byte_count}.",
            )
        total += byte_count
        if total > maximum_total_bytes:
            raise SidecarFailure("input.total-bytes", "Verified inputs exceed the total-byte safety bound.")
        metadata = value.get("metadata", {})
        if not isinstance(metadata, dict) or any(
            not isinstance(key, str) or not key or not isinstance(item, str)
            for key, item in metadata.items()
        ):
            raise SidecarFailure("input.metadata", "Input metadata must be string-to-string.")
        verified.append(
            VerifiedInput(
                identifier=value["id"],
                path=path,
                media_type=require_string(value, "mediaType"),
                role=require_string(value, "role"),
                byte_count=byte_count,
                sha256=digest,
                metadata=dict(metadata),
            )
        )
    return verified


def require_string(value: Mapping[str, Any], key: str) -> str:
    item = value.get(key)
    if not isinstance(item, str) or not item:
        raise SidecarFailure("value.string", f"{key} must be a nonempty string.")
    return item


def safe_relative_path(value: str) -> bool:
    if not value or value.startswith(("/", "\\")) or "\x00" in value or "\\" in value:
        return False
    parts = value.split("/")
    return all(part not in ("", ".", "..") for part in parts)


def resolve_under(root: Path, relative: str, must_exist: bool) -> Path:
    if not safe_relative_path(relative):
        raise SidecarFailure("path.unsafe", f"Unsafe relative path: {relative!r}")
    candidate = root.joinpath(*relative.split("/"))
    try:
        resolved = candidate.resolve(strict=must_exist)
    except OSError as error:
        raise SidecarFailure("path.resolve", f"Unable to resolve {relative}: {error}") from error
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise SidecarFailure("path.escape", f"Path escapes its declared root: {relative}") from error
    return resolved


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    count = 0
    try:
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(CHUNK_BYTES)
                if not chunk:
                    break
                digest.update(chunk)
                count += len(chunk)
    except OSError as error:
        raise SidecarFailure("file.read", f"Unable to hash {path}: {error}") from error
    return digest.hexdigest(), count


def write_json_atomic(value: Any, destination: Path, maximum_bytes: int) -> None:
    data = canonical_json_bytes(value)
    if len(data) > maximum_bytes:
        raise SidecarFailure(
            "output.size", f"Output has {len(data)} bytes, above the {maximum_bytes}-byte bound."
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise SidecarFailure("output.exists", f"Destination already exists: {destination}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=str(destination.parent)
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def make_artifact(
    *,
    path: Path,
    output_root: Path,
    logical_name: str,
    role: str,
    media_type: str,
    metadata: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    resolved_root = output_root.resolve(strict=True)
    resolved = path.resolve(strict=True)
    try:
        relative = resolved.relative_to(resolved_root).as_posix()
    except ValueError as error:
        raise SidecarFailure("artifact.path", f"Artifact escapes output root: {path}") from error
    digest, byte_count = sha256_file(resolved)
    if byte_count <= 0:
        raise SidecarFailure("artifact.empty", f"Artifact is empty: {relative}")
    return {
        "logicalName": logical_name,
        "role": role,
        "relativePath": relative,
        "mediaType": media_type,
        "byteCount": byte_count,
        "sha256": digest,
        "metadata": dict(metadata or {}),
    }


def make_response(
    request: LoadedRequest,
    *,
    status: str,
    artifacts: Sequence[Mapping[str, Any]] = (),
    diagnostics: Sequence[Mapping[str, Any]] = (),
    metrics: Mapping[str, float] | None = None,
    metadata: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    if status not in {"completed", "rejected", "failed"}:
        raise SidecarFailure("response.status", f"Invalid response status: {status}")
    return finite_json(
        {
            "schemaVersion": SCHEMA_VERSION,
            "requestID": request.value["requestID"],
            "requestSHA256": request.sha256,
            "sidecar": request.value["sidecar"],
            "operation": request.value["operation"],
            "status": status,
            "toolchain": request.value["toolchain"],
            "artifacts": list(artifacts),
            "diagnostics": list(diagnostics),
            "metrics": dict(metrics or {}),
            "metadata": dict(metadata or {}),
        }
    )


def diagnostic(severity: str, code: str, message: str, object_path: str | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {"severity": severity, "code": code, "message": message}
    if object_path is not None:
        result["objectPath"] = object_path
    return result


def finite_json(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            return None
        return value
    if isinstance(value, Mapping):
        return {str(key): finite_json(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [finite_json(item) for item in value]
    if hasattr(value, "item") and callable(value.item):
        return finite_json(value.item())
    if hasattr(value, "tolist") and callable(value.tolist):
        return finite_json(value.tolist())
    if isinstance(value, Iterable):
        return [finite_json(item) for item in value]
    return str(value)


def run_sidecar(
    *,
    request_path: Path,
    input_root: Path,
    output_root: Path,
    response_path: Path,
    expected_sidecar: str,
    allowed_operations: set[str],
    implementation: str,
    implementation_version: str,
    packages: Mapping[str, str],
    handler: Callable[[LoadedRequest, list[VerifiedInput], Path], tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, float], dict[str, str]]],
) -> int:
    request: LoadedRequest | None = None
    output_root.mkdir(parents=True, exist_ok=True)
    try:
        output_root = output_root.resolve(strict=True)
        response_path = response_path.resolve(strict=False)
        try:
            response_path.relative_to(output_root)
        except ValueError as error:
            raise SidecarFailure("response.path", "Response path must be inside output root.") from error
        request = load_request(request_path, expected_sidecar, allowed_operations)
        actual_packages = verify_toolchain(
            request,
            implementation=implementation,
            implementation_version=implementation_version,
            packages=packages,
        )
        inputs = verify_inputs(request, input_root)
        artifacts, diagnostics, metrics, metadata = handler(request, inputs, output_root)
        metadata = dict(metadata)
        metadata["implementation"] = implementation
        metadata["implementationVersion"] = implementation_version
        for name, version in actual_packages.items():
            metadata[f"package.{name}"] = version
        response = make_response(
            request,
            status="completed",
            artifacts=artifacts,
            diagnostics=diagnostics,
            metrics=metrics,
            metadata=metadata,
        )
        maximum = request.value["selection"]["maximumOutputBytes"]
        write_json_atomic(response, response_path, maximum)
        return 0
    except SidecarFailure as error:
        if request is not None:
            response = make_response(
                request,
                status="rejected",
                diagnostics=[diagnostic("error", error.code, error.message)],
                metadata={
                    "implementation": implementation,
                    "implementationVersion": implementation_version,
                },
            )
            try:
                maximum = request.value["selection"]["maximumOutputBytes"]
                write_json_atomic(response, response_path, maximum)
            except Exception:
                pass
        raise
