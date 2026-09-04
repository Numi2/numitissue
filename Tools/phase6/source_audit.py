#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
REQUIRED = {
    "Sources/NumiTissueIntegration/CultureTwin/CultureLeadField.swift": ["CultureLeadFieldBuilder", "CultureCurrentSource"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureRuntimeCurrentExtraction.swift": ["CultureRuntimeCurrentExtractor", "totalOutwardTransmembraneCurrentsAmperes"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureMeasurementElectronics.swift": ["CultureMeasurementProcessor", "CultureMeasurementModel"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureProductionSimulationProvider.swift": ["CultureProductionRuntimeDriver", "CultureProductionSimulationProvider"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureEvokedFeatures.swift": ["CultureEvokedFeatureExtractor"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureBaselineForecasters.swift": ["CultureBaselineForecaster"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureHierarchicalEvaluation.swift": ["CultureHierarchicalEvaluator"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureObservationEquivalence.swift": ["CultureObservationEquivalence"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureQualificationAuthority.swift": ["CultureQualificationAuthorityVerifier"],
    "Sources/NumiTissueIntegration/CultureTwin/CultureTwinQualification.swift": ["qualifyVerified", "file-backed authority verification"],
    "Sources/NumiTissueMetal/MetalCultureLeadField.swift": ["MetalCultureLeadField"],
    "Sources/NumiTissueMetal/Shaders/CultureLeadField.metal": ["kernel"],
    "Sources/NumiTissueData/Phase6CultureCorpus.swift": ["001268", "10.1016/j.iot.2025.101671"],
    "Sources/NumiTissueCLI/Phase6Command.swift": ["source-complete-unqualified", "hierarchical-score", "qualify"],
    "ValidationCases/CulturePhase6CompletionTests.swift": ["testTransmembraneCurrentUsesChargeAndAxialBalance"],
    "Docs/Validation/Phase6.md": ["Phase 6"],
}

errors: list[str] = []
texts: list[str] = []
for relative, needles in REQUIRED.items():
    path = ROOT / relative
    if not path.is_file():
        errors.append(f"missing required Phase 6 path: {relative}")
        continue
    text = path.read_text(encoding="utf-8")
    texts.append(text)
    for needle in needles:
        if needle not in text:
            errors.append(f"{relative}: missing contract token {needle!r}")

all_text = "\n".join(texts)
for marker in ("<<<<<<<", ">>>>>>>", "FIXME_PHASE6", "TODO_PHASE6"):
    if marker in all_text:
        errors.append(f"forbidden unresolved marker: {marker}")

# The Phase 6 authority must not issue a certificate from the digest-only API.
qualification = (ROOT / "Sources/NumiTissueIntegration/CultureTwin/CultureTwinQualification.swift")
if qualification.is_file():
    text = qualification.read_text(encoding="utf-8")
    digest_only = re.search(
        r"public static func qualify\([^}]+?\) throws -> CultureTwinQualificationCertificate \{(?P<body>.*?)\n    \}",
        text,
        re.S,
    )
    if not digest_only or "requires file-backed authority verification" not in digest_only.group("body"):
        errors.append("digest-only Phase 6 qualification is not fail-closed")

# Corpus targets cannot silently float on mutable DANDI aliases.
corpus = ROOT / "Sources/NumiTissueData/Phase6CultureCorpus.swift"
if corpus.is_file():
    text = corpus.read_text(encoding="utf-8")
    for required in ('publishedVersion.lowercased() != "draft"', 'publishedVersion.lowercased() != "latest"'):
        if required not in text:
            errors.append("Phase 6 DANDI pin does not reject mutable aliases")

if errors:
    print("Phase 6 source audit FAILED", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Phase 6 source audit passed ({len(REQUIRED)} required paths).")
