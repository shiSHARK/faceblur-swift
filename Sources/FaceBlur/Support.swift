// SPDX-License-Identifier: Apache-2.0
internal import FaceBlurCore
internal import FaceBlurOnnxRuntime
import Foundation
import Synchronization

/// Queues and the queue hop (ADR 0011 decision 4): blocking work never runs on the caller's thread, the main thread
/// or the cooperative pool.
enum Work {
    /// Model loading (read, hash, pre-parse).
    static let models = DispatchQueue(label: "io.github.shishark.faceblur.models", qos: .userInitiated,
                                      attributes: .concurrent)
    /// `PlanMasker` calls; parallel calls run in parallel.
    static let plans = DispatchQueue(label: "io.github.shishark.faceblur.plans", qos: .userInitiated,
                                     attributes: .concurrent)
    /// `FaceMasker.encodeJPEG` calls; parallel calls run in parallel.
    static let encoding = DispatchQueue(label: "io.github.shishark.faceblur.encoding", qos: .userInitiated,
                                        attributes: .concurrent)

    /// Runs `body` on `queue` and resumes with its result. Cancellation is checked before the hop and passed to the
    /// library through `token` while the body runs.
    static func onQueue<T: Sendable>(
        _ queue: DispatchQueue, token: Token? = nil,
        _ body: @escaping @Sendable () throws(FaceMaskError) -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let run: () async throws -> T = {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
                queue.async {
                    do { c.resume(returning: try body()) } catch { c.resume(throwing: FaceMaskError.forAsync(error)) }
                }
                Hooks.hopEnqueued()
            }
        }
        guard let token else { return try await run() }
        return try await withTaskCancellationHandler(operation: run, onCancel: { token.cancel() })
    }
}

/// The library's cancellation token, set from Swift's task cancellation handler.
final class Token: NSObject, CancellationToken, Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .releasing) }
    var isCancellationRequested: Bool { flag.load(ordering: .acquiring) }
}

/// Security-scoped access for the duration of one call, stopped on every path, and only if it was started.
enum SecurityScope {
    static func with<T>(_ url: URL, _ body: () throws(FaceMaskError) -> T) throws(FaceMaskError) -> T {
        let started = url.startAccessingSecurityScopedResource()
        Hooks.scopeStarted(started)
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
                Hooks.scopeStopped()
            }
        }
        return try body()
    }

    /// The URL's file-system path; `invalidConfiguration(parameter:)` for a URL that is not a file URL.
    static func path(_ url: URL, parameter: String) throws(FaceMaskError) -> String {
        guard url.isFileURL,
              let path = url.withUnsafeFileSystemRepresentation({ $0.map { String(cString: $0) } }), !path.isEmpty
        else { throw .invalidConfiguration(parameter: parameter) }
        return path
    }
}

/// Process-wide registration of the ONNX Runtime glue and the library version check (ADR 0011 decision 4).
enum Runtime {
    /// The version of the library this facade was built for (`FaceBlurIos.libraryVersion`).
    static let expectedLibraryVersion = "0.1.0"

    /// Run once, lazily, before the first `FaceMasker` is created.
    private static let ready: Bool = decide(
        register: { FaceBlurIos.shared.registerOnnxRuntime(factory: OnnxRuntimeGlueFactory()) },
        libraryVersion: FaceBlurIos.shared.libraryVersion)

    /// The facade never runs a bridge it does not know: `false` when another factory was registered first or the
    /// library binary is from another version.
    static func decide(register: () -> Bool, libraryVersion: String) -> Bool {
        libraryVersion == expectedLibraryVersion && register()
    }

    static func check() throws(FaceMaskError) {
        guard ready else { throw .runtimeUnavailable }
    }
}

/// Test hooks: counters only, no behaviour change.
enum Hooks {
    private static let copies = Atomic<Int>(0)
    private static let started = Atomic<Int>(0)
    private static let stopped = Atomic<Int>(0)
    private static let scans = Atomic<Int>(0)
    private static let scansOnMain = Atomic<Int>(0)
    private static let hops = Atomic<Int>(0)

    /// The single memory copy of a `.data` model into the library.
    static func modelCopy(_ base: UnsafeRawPointer, _ count: Int) throws(FaceMaskError) -> FaceBlurCore.ModelSource {
        copies.add(1, ordering: .relaxed)
        return try kotlinCall {
            try FaceBlurIos.shared.modelSourceFromMemory(address: Int64(Int(bitPattern: base)), byteCount: Int64(count))
        }
    }

    static func scopeStarted(_ ok: Bool) { if ok { started.add(1, ordering: .relaxed) } }
    static func scopeStopped() { stopped.add(1, ordering: .relaxed) }

    /// One CVPixelBuffer alpha scan, and whether it ran on the main thread (it must not).
    static func alphaScan() {
        scans.add(1, ordering: .relaxed)
        if Thread.isMainThread { scansOnMain.add(1, ordering: .relaxed) }
    }
    /// A call's work block was put on its queue (the caller is now suspended until the block has run).
    static func hopEnqueued() { hops.add(1, ordering: .relaxed) }

    static var modelCopies: Int { copies.load(ordering: .relaxed) }
    static var alphaScans: Int { scans.load(ordering: .relaxed) }
    static var alphaScansOnMain: Int { scansOnMain.load(ordering: .relaxed) }
    static var hopsEnqueued: Int { hops.load(ordering: .relaxed) }
    static var scopesStarted: Int { started.load(ordering: .relaxed) }
    static var scopesStopped: Int { stopped.load(ordering: .relaxed) }
}
