import Foundation

/// Optional capability for execution backends that commit development and glial topology changes
/// as part of the same biological transaction as the state update that generated them.
public protocol StructuralTopologyExecutionBackend: TissueExecutionBackend {
    func lastStructuralTopologyPlan() async -> StructuralTopologyPlan?
}

@inlinable
func max(_ a: Float, _ b: Float, _ c: Float) -> Float {
    Swift.max(Swift.max(a, b), c)
}
