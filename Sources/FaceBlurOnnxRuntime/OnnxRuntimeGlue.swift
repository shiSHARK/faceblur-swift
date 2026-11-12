// SPDX-License-Identifier: Apache-2.0
import FaceBlurCore
import FaceBlurOrtShim
import Foundation

/// ONNX Runtime 1.20.0 behind the library's `OnnxBridge` (ADR 0010). The session is created from the verified model
/// bytes in library memory through the runtime's C API (`CreateSessionFromArray`), so nothing is written to disk: no
/// model file, no cache, no optimised model. Only primitives cross per pass, no Objective-C object is created per pass,
/// and only status codes are returned, never error text.
public final class OnnxRuntimeGlue: NSObject, OnnxBridge {
    /// Int64 values per output-table row; equal to the Kotlin `OnnxBridge.OUTPUT_ROW_LONGS` (checked by a test).
    static let rowLongs = Int(FB_ORT_ROW_LONGS)

    private let lock = NSLock()
    private var session: OpaquePointer?
    private var provider = "CPU"

    public func open(
        modelAddress: Int64, modelByteCount: Int64, threads: Int32, inputName: String, inputShape: KotlinLongArray,
        outputNames: [String]
    ) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        fb_ort_close(session)
        session = nil
        provider = "CPU"
        guard inputShape.size == 4, modelByteCount > 0,
              let model = UnsafeRawPointer(bitPattern: Int(truncatingIfNeeded: modelAddress))
        else { return Int32(FB_ORT_INVALID_ARGUMENTS) }
        let shape = (0..<4).map { inputShape.get(index: Int32($0)) }
        let cores = Int32(clamping: ProcessInfo.processInfo.activeProcessorCount)
        var created: OpaquePointer?
        var xnnpack: Int32 = 0
        let status = Self.withCStrings(outputNames) { names in
            shape.withUnsafeBufferPointer { dims in
                fb_ort_open(
                    model, modelByteCount, threads, inputName, dims.baseAddress, 4, names, Int32(outputNames.count),
                    cores, &created, &xnnpack
                )
            }
        }
        guard status == Int32(FB_ORT_OK), let created else { return status }
        session = created
        provider = xnnpack == 1 ? "XNNPACK" : "CPU"
        return status
    }

    public func run(inputAddress: Int64, inputByteCount: Int64, outputTableAddress: Int64) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return Int32(FB_ORT_NOT_OPEN) }
        guard let input = UnsafeMutableRawPointer(bitPattern: Int(truncatingIfNeeded: inputAddress)),
              let table = UnsafeMutablePointer<Int64>(bitPattern: Int(truncatingIfNeeded: outputTableAddress))
        else { return Int32(FB_ORT_INVALID_ARGUMENTS) }
        return fb_ort_run(session, input, inputByteCount, table)
    }

    public func runtimeVersion() -> String { String(cString: fb_ort_version()) }

    public func executionProvider() -> String {
        lock.lock()
        defer { lock.unlock() }
        return provider
    }

    public func close() {
        lock.lock()
        fb_ort_close(session)
        session = nil
        lock.unlock()
    }

    deinit { fb_ort_close(session) }

    /// Calls `body` with a C array of NUL-terminated copies of `strings`, valid only during the call.
    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
        let copies = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers = copies.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}

/// Creates one glue per `FaceMasker`.
public final class OnnxRuntimeGlueFactory: NSObject, OnnxBridgeFactory {
    public func create() -> OnnxBridge { OnnxRuntimeGlue() }
}
