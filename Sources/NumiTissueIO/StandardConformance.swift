import Foundation

public enum ScientificInterchangeStandard: String, Codable, Sendable, CaseIterable, Hashable {
    case swc
    case neuroML = "neuroml"
    case lems
    case sonata
    case sbml
    case nmodl
    case nwb
}

public enum StandardImplementationPath: String, Codable, Sendable, CaseIterable, Hashable {
    case native
    case sidecar
    case nativeAndSidecar
    case none
}

public enum StandardConformanceDisposition: String, Codable, Sendable, CaseIterable, Hashable {
    case supported
    case loweredWithDeclaredApproximation
    case preservedNotExecutable
    case rejected
}

public struct StandardVersionContract: Codable, Sendable, Hashable {
    public var standard: ScientificInterchangeStandard
    public var specificationVersion: String
    public var specificationURI: String
    public var referenceImplementation: String?
    public var referenceImplementationVersion: String?
    public var notes: String?

    public init(
        standard: ScientificInterchangeStandard,
        specificationVersion: String,
        specificationURI: String,
        referenceImplementation: String? = nil,
        referenceImplementationVersion: String? = nil,
        notes: String? = nil
    ) {
        self.standard = standard
        self.specificationVersion = specificationVersion
        self.specificationURI = specificationURI
        self.referenceImplementation = referenceImplementation
        self.referenceImplementationVersion = referenceImplementationVersion
        self.notes = notes
    }

    public func validated() throws -> Self {
        guard !specificationVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let components = URLComponents(string: specificationURI),
              components.scheme == "https",
              components.host?.isEmpty == false,
              referenceImplementation?.isEmpty != true,
              referenceImplementationVersion?.isEmpty != true,
              notes?.isEmpty != true else {
            throw StandardConformanceError.invalidVersionContract(standard)
        }
        return self
    }
}

public struct StandardFeatureConformance: Codable, Sendable, Hashable {
    public var standard: ScientificInterchangeStandard
    public var featureID: String
    public var title: String
    public var disposition: StandardConformanceDisposition
    public var implementationPath: StandardImplementationPath
    public var implementationSymbols: [String]
    public var evidenceCaseIDs: [String]
    public var approximation: String?
    public var rejectionReason: String?
    public var notes: String?

    public init(
        standard: ScientificInterchangeStandard,
        featureID: String,
        title: String,
        disposition: StandardConformanceDisposition,
        implementationPath: StandardImplementationPath,
        implementationSymbols: [String] = [],
        evidenceCaseIDs: [String] = [],
        approximation: String? = nil,
        rejectionReason: String? = nil,
        notes: String? = nil
    ) {
        self.standard = standard
        self.featureID = featureID
        self.title = title
        self.disposition = disposition
        self.implementationPath = implementationPath
        self.implementationSymbols = implementationSymbols
        self.evidenceCaseIDs = evidenceCaseIDs
        self.approximation = approximation
        self.rejectionReason = rejectionReason
        self.notes = notes
    }

    public var stableIdentifier: String {
        "\(standard.rawValue).\(featureID)"
    }

    public func validated() throws -> Self {
        let trimmedID = featureID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              trimmedID == featureID,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              implementationSymbols.allSatisfy({ !$0.isEmpty }),
              evidenceCaseIDs.allSatisfy({ !$0.isEmpty }),
              Set(implementationSymbols).count == implementationSymbols.count,
              Set(evidenceCaseIDs).count == evidenceCaseIDs.count,
              approximation?.isEmpty != true,
              rejectionReason?.isEmpty != true,
              notes?.isEmpty != true else {
            throw StandardConformanceError.invalidFeature(stableIdentifier)
        }

        switch disposition {
        case .supported:
            guard implementationPath != .none,
                  !implementationSymbols.isEmpty,
                  approximation == nil,
                  rejectionReason == nil else {
                throw StandardConformanceError.invalidFeature(stableIdentifier)
            }
        case .loweredWithDeclaredApproximation:
            guard implementationPath != .none,
                  !implementationSymbols.isEmpty,
                  approximation != nil,
                  rejectionReason == nil else {
                throw StandardConformanceError.invalidFeature(stableIdentifier)
            }
        case .preservedNotExecutable:
            guard implementationPath != .none,
                  !implementationSymbols.isEmpty,
                  rejectionReason == nil else {
                throw StandardConformanceError.invalidFeature(stableIdentifier)
            }
        case .rejected:
            guard implementationPath == .none,
                  implementationSymbols.isEmpty,
                  rejectionReason != nil else {
                throw StandardConformanceError.invalidFeature(stableIdentifier)
            }
        }
        return self
    }
}

public struct StandardConformanceCoverage: Codable, Sendable, Hashable {
    public var supported: Int
    public var loweredWithDeclaredApproximation: Int
    public var preservedNotExecutable: Int
    public var rejected: Int
    public var evidenced: Int
    public var total: Int

    public init(features: [StandardFeatureConformance]) {
        supported = features.filter { $0.disposition == .supported }.count
        loweredWithDeclaredApproximation = features.filter {
            $0.disposition == .loweredWithDeclaredApproximation
        }.count
        preservedNotExecutable = features.filter {
            $0.disposition == .preservedNotExecutable
        }.count
        rejected = features.filter { $0.disposition == .rejected }.count
        evidenced = features.filter { !$0.evidenceCaseIDs.isEmpty }.count
        total = features.count
    }
}

public struct StandardConformanceMatrix: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var catalogVersion: String
    public var standards: [StandardVersionContract]
    public var features: [StandardFeatureConformance]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        catalogVersion: String,
        standards: [StandardVersionContract],
        features: [StandardFeatureConformance],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.standards = standards
        self.features = features
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !catalogVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !standards.isEmpty,
              !features.isEmpty,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw StandardConformanceError.invalidMatrix
        }
        for contract in standards { _ = try contract.validated() }
        for feature in features { _ = try feature.validated() }
        guard Set(standards.map(\.standard)).count == standards.count else {
            throw StandardConformanceError.duplicateStandard
        }
        let declared = Set(standards.map(\.standard))
        guard declared == Set(ScientificInterchangeStandard.allCases),
              features.allSatisfy({ declared.contains($0.standard) }) else {
            throw StandardConformanceError.undeclaredFeatureStandard
        }
        let identifiers = features.map(\.stableIdentifier)
        guard Set(identifiers).count == identifiers.count else {
            throw StandardConformanceError.duplicateFeature
        }
        return self
    }

    public func features(
        for standard: ScientificInterchangeStandard
    ) -> [StandardFeatureConformance] {
        features
            .filter { $0.standard == standard }
            .sorted { $0.featureID < $1.featureID }
    }

    public var coverage: StandardConformanceCoverage {
        StandardConformanceCoverage(features: features)
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public enum NumiTissueStandardConformance {
    public static var phase4Baseline: StandardConformanceMatrix {
        StandardConformanceMatrix(
            catalogVersion: "phase4-2026.09",
            standards: versionContracts,
            features: featureContracts,
            metadata: [
                "authority": "NumiTissueIO",
                "native-contract": "source-symbols plus executable validation cases",
                "sidecar-contract": "version-pinned request/response protocol",
                "unsupported-policy": "reject rather than silently reinterpret"
            ]
        )
    }

    private static var versionContracts: [StandardVersionContract] {
        [
            StandardVersionContract(
                standard: .swc,
                specificationVersion: "INCF SWC specification",
                specificationURI: "https://swc-specification.readthedocs.io/en/latest/swc.html",
                referenceImplementation: "INCF/swc-specification",
                referenceImplementationVersion: "67a18f96db524d03430f15936755a79ce68c23be"
            ),
            StandardVersionContract(
                standard: .neuroML,
                specificationVersion: "2.3",
                specificationURI: "https://docs.neuroml.org/Userdocs/NeuroMLv2.html",
                referenceImplementation: "NeuroML/NeuroML2",
                referenceImplementationVersion: "a5f5dadccd23606e683eaa0dd58dd2c3b2a7ed58"
            ),
            StandardVersionContract(
                standard: .lems,
                specificationVersion: "0.7.6",
                specificationURI: "https://docs.neuroml.org/Userdocs/LEMSSchema.html",
                referenceImplementation: "NeuroML/LEMS",
                referenceImplementationVersion: "0.7.6"
            ),
            StandardVersionContract(
                standard: .sonata,
                specificationVersion: "1.x",
                specificationURI: "https://github.com/AllenInstitute/sonata/blob/master/docs/SONATA_DEVELOPER_GUIDE.md",
                referenceImplementation: "AllenInstitute/sonata",
                referenceImplementationVersion: "51f247bb58bec6264f5d20d31b25ddf40d5c6eb6"
            ),
            StandardVersionContract(
                standard: .sbml,
                specificationVersion: "Level 3 Version 2 Core Release 2",
                specificationURI: "https://sbml.org/documents/specifications/level-3/version-2/core/release-2/",
                referenceImplementation: "libSBML"
            ),
            StandardVersionContract(
                standard: .nmodl,
                specificationVersion: "restricted NEURON NMODL subset",
                specificationURI: "https://nrn.readthedocs.io/en/latest/nmodl/index.html",
                referenceImplementation: "NEURON NMODL",
                notes: "NMODL has no single interchange-version number; NumiTissue publishes an executable subset contract."
            ),
            StandardVersionContract(
                standard: .nwb,
                specificationVersion: "2.10.0",
                specificationURI: "https://nwb-schema.readthedocs.io/en/stable/format.html",
                referenceImplementation: "PyNWB",
                referenceImplementationVersion: "4.1.0"
            )
        ]
    }

    private static var featureContracts: [StandardFeatureConformance] {
        [
            feature(.swc, "seven-column-tree", "Seven-column morphology tree", .supported, .native,
                    ["SWCImporter.parse", "SWCMorphology.validated", "SWCExporter.encode"],
                    ["phase4.swc.round-trip"]),
            feature(.swc, "comments-metadata", "Comments and key-value metadata", .supported, .native,
                    ["SWCImporter.parse", "SWCExporter.encode"],
                    ["phase4.swc.metadata"]),
            feature(.swc, "custom-node-types", "Custom integer node type codes", .supported, .native,
                    ["SWCNode.customKind", "SWCImporter.parse"],
                    ["phase4.swc.custom-type"]),
            feature(.swc, "swc-plus-extensions", "SWC+ structured extensions", .preservedNotExecutable, .native,
                    ["SWCMorphology.metadata"],
                    notes: "Unknown extension comments remain available as metadata; they do not alter runtime topology."),

            feature(.neuroML, "morphology", "Cells, segments, segment groups and inclusions", .supported, .native,
                    ["NeuroMLImporter.parse", "NeuroMLCell.asSWC", "CircuitRuntimeCompiler.compile"],
                    ["phase4.neuroml.morphology"]),
            feature(.neuroML, "passive-properties", "Specific capacitance and axial resistivity", .preservedNotExecutable, .native,
                    ["NeuroMLCell.specificCapacitance", "NeuroMLCell.resistivity"],
                    ["phase4.neuroml.passive"],
                    notes: "Values are parsed and preserved. The current morphology lowering path does not yet apply them to runtime compartments."),
            feature(.neuroML, "channel-density", "Channel density variants", .preservedNotExecutable, .native,
                    ["NeuroMLChannelDensity", "NeuroMLImporter.parse"],
                    ["phase4.neuroml.channel-density"],
                    notes: "Declarations are parsed and preserved but are not yet compiled into authoritative mechanism tables."),
            feature(.neuroML, "include-declarations", "External include declarations", .preservedNotExecutable, .native,
                    ["NeuroMLDocument.includes", "NeuroMLImporter.parse"],
                    ["phase4.neuroml.includes"],
                    notes: "Include paths are preserved; recursive resolution belongs to corpus materialization."),

            feature(.lems, "dimensions-units", "Dimensions and units", .supported, .native,
                    ["LEMSXMLImporter.parse", "LEMSDimension", "LEMSUnitDefinition"],
                    ["phase4.lems.units"]),
            feature(.lems, "component-types", "Component types, parameters and state variables", .preservedNotExecutable, .native,
                    ["LEMSComponentTypeDefinition", "LEMSDynamicsDefinition"],
                    ["phase4.lems.component-type"],
                    notes: "Definitions are parsed and validated; general LEMS component execution is not an authoritative runtime path."),
            feature(.lems, "continuous-event-dynamics", "Derivatives, regimes and event transitions", .preservedNotExecutable, .native,
                    ["LEMSTimeDerivativeDefinition", "LEMSRegimeDefinition", "LEMSOnConditionDefinition", "LEMSOnEventDefinition"],
                    ["phase4.lems.dynamics"],
                    notes: "Dynamics remain portable interchange state until explicitly lowered."),
            feature(.lems, "arbitrary-procedural-code", "Embedded procedural or host-language code", .rejected, .none,
                    rejectionReason: "The portable expression and mechanism IR exclude arbitrary executable host code."),

            feature(.sonata, "configuration-json", "Manifest substitution and circuit configuration", .supported, .native,
                    ["SONATACircuitConfiguration", "SONATAConfigurationLoader.load"],
                    ["phase4.sonata.configuration"]),
            feature(.sonata, "in-memory-nodes-edges", "Typed node and edge records", .supported, .native,
                    ["SONATANodePopulation", "SONATAEdgePopulation", "CircuitRuntimeCompiler.compileSONATA"],
                    ["phase4.sonata.records"]),
            feature(.sonata, "hdf5-node-edge-store", "SONATA HDF5 node and edge tables", .supported, .sidecar,
                    ["Tools/numitissue-reference/numitissue_reference.py"],
                    ["phase4.sonata.sidecar-contract"],
                    notes: "The Swift runtime consumes canonical records; HDF5 materialization is delegated to a pinned sidecar."),
            feature(.sonata, "reports", "SONATA simulation reports and spike files", .preservedNotExecutable, .sidecar,
                    ["Tools/numitissue-reference/numitissue_reference.py"],
                    notes: "Reports are evidence inputs and are not interpreted as executable circuit definitions."),

            feature(.sbml, "core-model", "Compartments, species, parameters and reactions", .supported, .native,
                    ["SBMLXMLImporter.parse", "SBMLDocumentModel", "SBMLToMolecularIRCompiler.compile", "MolecularProgramIR"],
                    ["phase4.sbml.core"]),
            feature(.sbml, "mathml-subset", "Portable MathML expression subset", .supported, .native,
                    ["PortableExpressionIR", "SBMLXMLImporter.parse"],
                    ["phase4.sbml.mathml"]),
            feature(.sbml, "assignments-rules", "Initial assignments and assignment rules", .loweredWithDeclaredApproximation, .native,
                    ["SBMLInitialAssignmentDefinition", "SBMLAssignmentRuleDefinition", "MolecularObservableIR"],
                    ["phase4.sbml.rules"],
                    approximation: "Supported assignments lower into initial symbols and portable observables. Unsupported ordering or package semantics are rejected."),
            feature(.sbml, "level3-packages", "Arbitrary SBML Level 3 package semantics", .rejected, .none,
                    rejectionReason: "Only declared core constructs and explicitly implemented package subsets may execute."),

            feature(.nmodl, "mechanism-blocks", "NEURON, PARAMETER, STATE, ASSIGNED and executable mechanism blocks", .supported, .native,
                    ["NMODLImporter.parse", "NMODLCompiler.compile", "MechanismBytecodeCompiler.compile"],
                    ["phase4.nmodl.mechanism"]),
            feature(.nmodl, "derivative-kinetic", "Restricted DERIVATIVE and KINETIC integration", .loweredWithDeclaredApproximation, .native,
                    ["MechanismModelIR", "MechanismBytecode", "MechanismBytecodeCompiler.compile"],
                    ["phase4.nmodl.integration"],
                    approximation: "Supported equations lower to bounded bytecode integrators with explicit state layout and solver selection."),
            feature(.nmodl, "verbatim-pointer", "VERBATIM, POINTER and arbitrary external linkage", .rejected, .none,
                    rejectionReason: "Arbitrary native code and external memory references violate portability, determinism and GPU safety."),

            feature(.nwb, "schema-validation", "NWB core and extension schema validation", .supported, .sidecar,
                    ["Tools/numitissue-nwb/numitissue_nwb.py"],
                    ["phase4.nwb.request-contract"]),
            feature(.nwb, "session-metadata", "Session, subject, device and provenance metadata", .supported, .sidecar,
                    ["Tools/numitissue-nwb/numitissue_nwb.py"],
                    ["phase4.nwb.metadata"]),
            feature(.nwb, "electrodes-units-events", "Electrodes, units, spike times and interval tables", .supported, .sidecar,
                    ["Tools/numitissue-nwb/numitissue_nwb.py"],
                    ["phase4.nwb.neural-data"]),
            feature(.nwb, "bounded-timeseries", "Bounded time-series extraction", .supported, .sidecar,
                    ["Tools/numitissue-nwb/numitissue_nwb.py"],
                    ["phase4.nwb.bounded-extraction"])
        ]
    }

    private static func feature(
        _ standard: ScientificInterchangeStandard,
        _ featureID: String,
        _ title: String,
        _ disposition: StandardConformanceDisposition,
        _ implementationPath: StandardImplementationPath,
        _ symbols: [String] = [],
        _ evidence: [String] = [],
        approximation: String? = nil,
        rejectionReason: String? = nil,
        notes: String? = nil
    ) -> StandardFeatureConformance {
        StandardFeatureConformance(
            standard: standard,
            featureID: featureID,
            title: title,
            disposition: disposition,
            implementationPath: implementationPath,
            implementationSymbols: symbols,
            evidenceCaseIDs: evidence,
            approximation: approximation,
            rejectionReason: rejectionReason,
            notes: notes
        )
    }
}

public enum StandardConformanceError: Error, Sendable, CustomStringConvertible {
    case invalidVersionContract(ScientificInterchangeStandard)
    case invalidFeature(String)
    case invalidMatrix
    case duplicateStandard
    case undeclaredFeatureStandard
    case duplicateFeature

    public var description: String {
        switch self {
        case .invalidVersionContract(let standard):
            return "Invalid version contract for \(standard.rawValue)."
        case .invalidFeature(let identifier):
            return "Invalid conformance feature \(identifier)."
        case .invalidMatrix:
            return "The standard conformance matrix is invalid."
        case .duplicateStandard:
            return "The conformance matrix declares a standard more than once."
        case .undeclaredFeatureStandard:
            return "A conformance feature references an undeclared or missing standard."
        case .duplicateFeature:
            return "The conformance matrix contains duplicate feature identifiers."
        }
    }
}
