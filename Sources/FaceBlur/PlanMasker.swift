// SPDX-License-Identifier: Apache-2.0
internal import FaceBlurCore
import Foundation

/// Masks files with masks from the app's own detector: no model and no ONNX Runtime. Calls run on a private
/// concurrent queue of FaceBlur, so parallel calls run in parallel; never on the main thread or the cooperative pool.
public struct PlanMasker: Sendable {
    public let masking: MaskingConfiguration

    public init(masking: MaskingConfiguration = .default) {
        self.masking = masking
    }

    /// Decodes the file at its working size and returns a plan bound to it. Coordinates are pixels
    /// of the working image. Throws ``FaceMaskError`` or `CancellationError`.
    public func planFile(at source: URL, options: FileOptions = .default) async throws -> MaskPlan {
        let path = try SecurityScope.path(source, parameter: "source")
        let masking = masking
        let token = Token()
        let plan: KotlinRef<FaceBlurCore.MaskPlan> = try await Work.onQueue(Work.plans, token: token) {
            () throws(FaceMaskError) in
            let k = FaceBlurCore.PlanMasker(masking: try masking.kotlin())
            let o = try options.kotlin()
            return try SecurityScope.with(source) { () throws(FaceMaskError) in
                KotlinRef(try kotlinCall { try k.planFile(source: path, options: o, cancellation: token) })
            }
        }
        return MaskPlan(plan.value)
    }

    /// Writes the plan's masks into the file and writes a JPEG to `target`, as ``FaceMasker/maskFile(at:to:options:plan:)``.
    /// The plan must come from ``planFile(at:options:)`` for this file (edited with ``MaskPlan/withMasks(_:)``).
    /// Throws ``FaceMaskError`` or `CancellationError`.
    public func maskFile(at source: URL, to target: OutputTarget, plan: MaskPlan,
                         options: FileOptions = .default) async throws -> FileResult {
        let path = try SecurityScope.path(source, parameter: "source")
        let masking = masking
        let token = Token()
        return try await Work.onQueue(Work.plans, token: token) { () throws(FaceMaskError) in
            let k = FaceBlurCore.PlanMasker(masking: try masking.kotlin())
            let o = try options.kotlin()
            let p = try plan.kotlinForFile()
            return try FileTarget.with(source: source, target: target) { (t) throws(FaceMaskError) in
                FileResult(try kotlinCall {
                    try k.maskFile(source: path, target: t, plan: p, options: o, cancellation: token)
                })
            }
        }
    }
}
