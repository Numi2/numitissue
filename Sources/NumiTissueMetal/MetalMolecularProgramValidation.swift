#if canImport(Metal)
import Foundation
import NumiTissueModels
import NumiTissueRuntime

/// Shared validation for classic and Metal 4 execution. It rejects model/program mismatches before
/// any GPU state is allocated, keeping failures deterministic and non-mutating.
public enum MetalMolecularProgramValidator {
    public static func validate(
        model: CompiledTissueModel,
        initialState: TissueRuntimeState,
        program: MetalMolecularProgram
    ) throws {
        guard model.microdomainHeaders.count == initialState.microdomains.count else {
            throw MetalRuntimeError.unsupported(
                "compiled model has \(model.microdomainHeaders.count) molecular domain header(s), but the initial state has \(initialState.microdomains.count)"
            )
        }
        guard !model.microdomainHeaders.isEmpty else { return }
        guard !program.networks.isEmpty else {
            throw MetalRuntimeError.unsupported(
                "compiled tissue model contains molecular domains but no Metal molecular program was provided"
            )
        }

        for (domainIndex, domain) in initialState.microdomains.enumerated() {
            let networkIndex = Int(domain.reactionNetworkIndex)
            guard networkIndex < program.networks.count else {
                throw MetalRuntimeError.unsupported(
                    "molecular domain \(domainIndex) references network \(networkIndex), but the program contains \(program.networks.count)"
                )
            }
            let network = program.networks[networkIndex]
            guard Int(domain.speciesRange.count) == Int(network.speciesCount) else {
                throw MetalRuntimeError.unsupported(
                    "molecular domain \(domainIndex) has \(domain.speciesRange.count) species, but network \(networkIndex) requires \(network.speciesCount)"
                )
            }
            let lower = Int(domain.speciesRange.lowerBound)
            let count = Int(domain.speciesRange.count)
            guard lower <= initialState.molecularSpecies.count,
                  count <= initialState.molecularSpecies.count - lower else {
                throw MetalRuntimeError.unsupported(
                    "molecular domain \(domainIndex) species range is outside the molecular state pool"
                )
            }
            guard UInt64(network.reactionOffset) + UInt64(network.reactionCount) <=
                    UInt64(program.reactions.count) else {
                throw MetalRuntimeError.unsupported(
                    "molecular network \(networkIndex) reaction range is outside the Metal program"
                )
            }

            for reactionIndex in 0..<Int(network.reactionCount) {
                let reaction = program.reactions[
                    Int(network.reactionOffset) + reactionIndex
                ]
                guard reaction.rateConstant.isFinite,
                      reaction.rateConstant >= 0,
                      reaction.reverseRateConstant.isFinite,
                      reaction.reverseRateConstant >= 0 else {
                    throw MetalRuntimeError.unsupported(
                        "molecular network \(networkIndex) reaction \(reactionIndex) has a non-finite or negative rate"
                    )
                }
                for lane in 0..<4 {
                    try validateSpeciesLane(
                        species: reaction.reactants[lane],
                        coefficient: reaction.reactantStoichiometry[lane],
                        speciesCount: network.speciesCount,
                        role: "reactant",
                        networkIndex: networkIndex,
                        reactionIndex: reactionIndex
                    )
                    try validateSpeciesLane(
                        species: reaction.products[lane],
                        coefficient: reaction.productStoichiometry[lane],
                        speciesCount: network.speciesCount,
                        role: "product",
                        networkIndex: networkIndex,
                        reactionIndex: reactionIndex
                    )
                }
            }
        }
    }

    private static func validateSpeciesLane(
        species: UInt32,
        coefficient: Int8,
        speciesCount: UInt32,
        role: String,
        networkIndex: Int,
        reactionIndex: Int
    ) throws {
        if species == UInt32.max {
            guard coefficient == 0 else {
                throw MetalRuntimeError.unsupported(
                    "molecular network \(networkIndex) reaction \(reactionIndex) has a coefficient for an empty \(role) lane"
                )
            }
        } else {
            guard species < speciesCount, coefficient > 0 else {
                throw MetalRuntimeError.unsupported(
                    "molecular network \(networkIndex) reaction \(reactionIndex) has an invalid \(role)"
                )
            }
        }
    }
}
#endif
