import Foundation
import NumiTissueCore

// MARK: - Validation

extension TissueModelCompiler {
    func validate(_ model: TissueModel) throws {
        guard model.schemaVersion == NumiTissueBuild.modelSchemaVersion else {
            throw ModelValidationError.unsupportedSchema(model.schemaVersion)
        }
        guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError.unknownReference("model name")
        }

        try requireUnique(model.populations.map(\.name))
        try requireUnique(model.morphologies.map(\.name))
        try requireUnique(model.mechanismSets.map(\.name))
        try requireUnique(model.cellPrototypes.map(\.name))
        try requireUnique(model.synapsePrototypes.map(\.name))
        try requireUnique(model.regulatoryPrograms.map(\.name))
        try requireUnique(model.glialPrograms.map(\.name))
        try requireUnique(model.molecularNetworks.map(\.name))
        try requireUniqueIDs(model.populations.map { $0.id.rawValue })
        try requireUniqueIDs(model.cells.map { $0.id.rawValue })
        try requireUniqueIDs(model.synapses.map { $0.id.rawValue })
        try requireUniqueIDs(model.molecularDomains.map { $0.id.rawValue })

        for morphology in model.morphologies { try morphology.validate() }

        let morphologyNames = Set(model.morphologies.map(\.name))
        let mechanismNames = Set(model.mechanismSets.map(\.name))
        let regulatoryNames = Set(model.regulatoryPrograms.map(\.name))
        let glialNames = Set(model.glialPrograms.map(\.name))
        for prototype in model.cellPrototypes {
            guard prototype.radiusMicrometers > 0,
                  prototype.membraneCapacitance > 0,
                  prototype.leakConductance >= 0 else {
                throw ModelValidationError.unknownReference(
                    "invalid cell prototype \(prototype.name)"
                )
            }
            if let name = prototype.morphology, !morphologyNames.contains(name) {
                throw ModelValidationError.unknownReference("morphology \(name)")
            }
            if let name = prototype.mechanismSet, !mechanismNames.contains(name) {
                throw ModelValidationError.unknownReference("mechanism set \(name)")
            }
            if let name = prototype.regulatoryProgram, !regulatoryNames.contains(name) {
                throw ModelValidationError.unknownReference("regulatory program \(name)")
            }
            if let name = prototype.glialProgram, !glialNames.contains(name) {
                throw ModelValidationError.unknownReference("glial program \(name)")
            }
        }

        let prototypeNames = Set(model.cellPrototypes.map(\.name))
        let populationIDs = Set(model.populations.map(\.id))
        for cell in model.cells {
            guard prototypeNames.contains(cell.prototype) else {
                throw ModelValidationError.unknownReference(
                    "cell prototype \(cell.prototype)"
                )
            }
            guard populationIDs.contains(cell.population) else {
                throw ModelValidationError.unknownReference(
                    "population \(cell.population)"
                )
            }
            guard cell.positionMicrometers.x.isFinite,
                  cell.positionMicrometers.y.isFinite,
                  cell.positionMicrometers.z.isFinite else {
                throw ModelValidationError.unknownReference(
                    "non-finite position for cell \(cell.id)"
                )
            }
        }

        let cellIDs = Set(model.cells.map(\.id))
        let synapseNames = Set(model.synapsePrototypes.map(\.name))
        for synapse in model.synapses {
            guard cellIDs.contains(synapse.presynapticCell),
                  cellIDs.contains(synapse.postsynapticCell),
                  synapseNames.contains(synapse.prototype),
                  synapse.delayMilliseconds >= 0,
                  synapse.delayMilliseconds.isFinite else {
                throw ModelValidationError.invalidSynapse(synapse.id.description)
            }
        }

        let networkNames = Set(model.molecularNetworks.map(\.name))
        for domain in model.molecularDomains {
            guard cellIDs.contains(domain.cell), networkNames.contains(domain.network) else {
                throw ModelValidationError.unknownReference(
                    "molecular domain \(domain.id)"
                )
            }
        }
        for network in model.molecularNetworks {
            guard !network.species.isEmpty,
                  network.species.count <= 64,
                  network.reactions.count <= 128,
                  network.voxelCount >= 1,
                  network.voxelCount <= 64 else {
                throw ModelValidationError.invalidMolecularNetwork(network.name)
            }
            try requireUnique(network.species.map(\.name))
            try requireUnique(network.reactions.map(\.name))
            let speciesNames = Set(network.species.map(\.name))
            for reaction in network.reactions {
                guard reaction.forwardRate >= 0,
                      reaction.forwardRate.isFinite,
                      reaction.reverseRate.map({ $0 >= 0 && $0.isFinite }) ?? true,
                      reaction.reactants.count <= 2,
                      reaction.products.count <= 2,
                      reaction.reactants.allSatisfy({ speciesNames.contains($0.species) }),
                      reaction.products.allSatisfy({ speciesNames.contains($0.species) }) else {
                    throw ModelValidationError.invalidMolecularNetwork(
                        "\(network.name)/\(reaction.name)"
                    )
                }
            }
        }
    }

    func requireUnique(_ values: [String]) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            throw ModelValidationError.duplicateName(value)
        }
    }

    func requireUniqueIDs(_ values: [UInt64]) throws {
        var seen = Set<UInt64>()
        for value in values where !seen.insert(value).inserted {
            throw ModelValidationError.duplicateIdentifier(value)
        }
    }
}
