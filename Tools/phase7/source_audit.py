#!/usr/bin/env python3
"""Bounded Phase 7 source preflight. Does not compile, execute or qualify the simulator."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

REQUIRED = {
    "Sources/NumiTissueIntegration/ClosedLoop/ClosedLoopContracts.swift": [
        "ClosedLoopClockMap", "ClosedLoopSafetyEnvelope", "InterlockedNeuralCultureBackend"],
    "Sources/NumiTissueIntegration/ClosedLoop/ClosedLoopSafetyEvaluator.swift": [
        "checkCumulative", "history + result", "rebuilt == request.plan", "ceilTicks"],
    "Sources/NumiTissueIntegration/ClosedLoop/GuardedNeuralCultureSession.swift": [
        "ClosedLoopAdmissionVerifier", "WatchdogNeuralCultureBackend", "ambiguousDelivery",
        "expected * Double(request.electrodeIDs.count)", "recording.frame.sampleCount == Int(expected.rounded())",
        "requests[request.id] = request", "stimulation-intent", "latestObservationSHA256", "public func reconcile"],
    "Sources/NumiTissueIntegration/ClosedLoop/ClosedLoopJournal.swift": [
        "O_EXCL", "O_NOFOLLOW", "synchronize()", "poisoned = true", "ClosedLoopJournalVerifier"],
    "Sources/NumiTissueIntegration/ClosedLoop/DurableSuiteJournal.swift": [
        "LOCK_EX", "LOCK_NB", "commit-decided", "reopenExisting", "recoveryDecisions", "synchronize()"],
    "Sources/NumiTissueIntegration/ClosedLoop/PreparedTissueBackendAdapter.swift": [
        "lastCommitted", "exportCommittedState", "prepareSuiteCommit", "commitSuitePrepared"],
    "Sources/NumiTissueIntegration/ClosedLoop/SnapshotSuiteEndpoints.swift": [
        "SnapshotNumiBrainEndpoint", "SnapshotNumanXEndpoint", "mutation after prepare", "previousCommit"],
    "Sources/NumiTissueIntegration/ClosedLoop/ReplayNeuralCultureBackend.swift": [
        "NonphysicalNeuralCultureBackend", "ClosedLoopRunner", "cancel", "Simulated acceptance"],
    "Sources/NumiTissueIntegration/ClosedLoop/RCNeuralInterfaceEmulator.swift": [
        "NonphysicalNeuralCultureBackend", "SOFTWARE-ONLY", "exp(", "edges.removeFirst"],
    "Sources/NumiTissueIntegration/ClosedLoop/DeviceStimulationSchedule.swift": [
        "timestampQuantumNanoseconds", "phaseQuantumNanoseconds", "not exactly representable"],
    "Sources/NumiTissueIntegration/ClosedLoop/ClosedLoopReplayExample.swift": [
        "software-replay-not-biological-evidence", "ClosedLoopRunner.run"],
    "Sources/NumiTissueIntegration/SuiteCoordinator.swift": [
        "decisionAttempted = true", "recordCommitDecision", "recoverCommit", "requirePreparedParticipants",
        "publication fence is closed", "journal cannot represent in-doubt"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureRuntimeCurrentExtraction.swift": [
        "ionicAndSynapticOutwardAmperes", "let all = Double(c.injectedCurrentNanoamps) + axial[i]",
        "let channels = all - capacitive", "cyclic compartment graph"],
    "Sources/NumiTissueCLI/Phase7Command.swift": [
        "replay-example", "safety-check", "suite-recovery-inspect", "not-established"],
    "Sources/NumiTissueCLI/CLIEntryPoint.swift": ["case \"phase7\": try await Phase7Command.run"],
    "ValidationCases/Phase7ClosedLoopSafetyTests.swift": ["testLostAcknowledgementStopsAndIsNeverResubmitted"],
    "ValidationCases/Phase7SuiteRecoveryTests.swift": ["testPartialPublicationNeverRollsBackAndCanRecoverIdempotently"],
    "ValidationCases/Phase7DeviceTimingTests.swift": ["testRCEmulatorRespondsToActualQueuedPulseAndDeduplicatesID"],
    "Docs/Validation/Phase7.md": ["Uncompiled, unexecuted", "Cross-process automatic recovery is not implemented"],
    "Examples/Phase7/README.md": ["replay-example", "synthetic"],
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    root = args.root.resolve()
    errors: list[str] = []
    sources: dict[str, str] = {}
    for relative, markers in REQUIRED.items():
        path = root / relative
        if not path.is_file():
            errors.append(f"missing file: {relative}")
            continue
        if path.stat().st_size > 2 * 1024 * 1024:
            errors.append(f"unexpectedly large source: {relative}")
            continue
        text = path.read_text(encoding="utf-8")
        sources[relative] = text
        for marker in markers:
            if marker not in text:
                errors.append(f"{relative}: missing contract anchor {marker!r}")
        if re.search(r"^(<<<<<<<|=======|>>>>>>>)", text, re.MULTILINE):
            errors.append(f"merge-conflict marker: {relative}")

    coordinator = sources.get("Sources/NumiTissueIntegration/SuiteCoordinator.swift", "")
    if "rollbackAll(" in coordinator:
        errors.append("legacy broad rollback helper remains in the coordinator")
    decision = coordinator.find("decisionAttempted = true")
    record = coordinator.find("try await journal.recordCommitDecision", max(decision, 0))
    publish = coordinator.find("try await publish", max(record, 0))
    if not 0 <= decision < record < publish:
        errors.append("commit decision is not visibly ordered before publication")

    guarded = sources.get("Sources/NumiTissueIntegration/ClosedLoop/GuardedNeuralCultureSession.swift", "")
    reserve = guarded.find("requests[request.id] = request")
    intent = guarded.find('try await log("stimulation-intent"', max(reserve, 0))
    dispatch = guarded.find("try await backend.stimulate", max(intent, 0))
    if not 0 <= reserve < intent < dispatch:
        errors.append("dose reservation and durable intent are not ordered before dispatch")

    test_names = []
    for path, source in sources.items():
        if path.startswith("ValidationCases/Phase7"):
            test_names.extend(re.findall(r"func\s+(test\w+)\s*\(", source))
    if len(test_names) != len(set(test_names)):
        errors.append("duplicate Phase 7 test names")
    if len(test_names) < 20:
        errors.append("Phase 7 regression source coverage unexpectedly small")

    result = {
        "kind": "source-contract-preflight-only",
        "checkedFiles": len(sources),
        "testMethodsPresent": len(test_names),
        "passed": not errors,
        "errors": errors,
        "swiftCompiled": False,
        "testsExecuted": False,
        "hardwareQualified": False,
        "biologicallyValidated": False,
    }
    print(json.dumps(result, sort_keys=True, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
