// SPDX-License-Identifier: Apache-2.0
import FaceBlurCore
import FaceBlurOnnxRuntime
import Foundation

/// What one test needs to know about the glue it made stuck: the gate that holds its run, and what the library did
/// to the glue meanwhile.
final class StuckRun: @unchecked Sendable {
    /// Signalled by the test (teardown at the latest) to let the stuck run go on.
    let release = DispatchSemaphore(value: 0)
    /// Signalled when the glue's `close()` has finished.
    let closed = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var contract: Double = 0
    private var runs = 0
    private var attempts = 0
    private var finished = 0

    /// The wall time of the glue's first run (the contract run at creation), in milliseconds.
    var contractMillis: Double { lock.withLock { contract } }
    /// How many `run` calls reached the glue.
    var runCount: Int { lock.withLock { runs } }
    /// How many times anyone called `close()` on the glue (counted before the glue's lock is taken).
    var closeAttempts: Int { lock.withLock { attempts } }
    /// How many `close()` calls got through the glue's lock.
    var closesFinished: Int { lock.withLock { finished } }

    func countRun(_ number: Int) { lock.withLock { runs = number } }
    func setContract(_ millis: Double) { lock.withLock { contract = millis } }
    func countCloseAttempt() { lock.withLock { attempts += 1 } }
    func countCloseFinished() { lock.withLock { finished += 1 } }

    /// Lets the stuck run go on (idempotent in effect: one waiter, one signal).
    func letGo() { release.signal() }
}

/// The production glue behind a test wrapper. Every call goes to a real `OnnxRuntimeGlue` (ONNX Runtime 1.20.0), with
/// one difference: when the glue is armed, its second `run` (the first pass of a call, after the contract run at
/// creation) first waits on a semaphore inside Swift, with no CPU, until the test lets it go. The wrapper keeps the
/// production glue's lock discipline: `run` and `close` both hold one `NSLock`, so a `close()` from another thread
/// waits for a stuck `run` exactly as it does in `OnnxRuntimeGlue`.
final class BlockingGlue: NSObject, OnnxBridge, @unchecked Sendable {
    /// The longest a stuck run waits if the test never lets it go (a safety stop, not a test parameter).
    static let safetyStopSeconds = 60.0

    private let inner = OnnxRuntimeGlue()
    private let lock = NSLock()
    private let stuck: StuckRun?
    private var runs = 0

    init(stuck: StuckRun?) {
        self.stuck = stuck
        super.init()
    }

    func open(
        modelAddress: Int64, modelByteCount: Int64, threads: Int32, inputName: String, inputShape: KotlinLongArray,
        outputNames: [String]
    ) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return inner.open(
            modelAddress: modelAddress, modelByteCount: modelByteCount, threads: threads, inputName: inputName,
            inputShape: inputShape, outputNames: outputNames)
    }

    func run(inputAddress: Int64, inputByteCount: Int64, outputTableAddress: Int64) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        runs += 1
        guard let stuck else {
            return inner.run(inputAddress: inputAddress, inputByteCount: inputByteCount,
                             outputTableAddress: outputTableAddress)
        }
        stuck.countRun(runs)
        if runs >= 2 {
            // Inside Swift, holding this glue's lock, no CPU.
            _ = stuck.release.wait(timeout: .now() + Self.safetyStopSeconds)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let status = inner.run(inputAddress: inputAddress, inputByteCount: inputByteCount,
                               outputTableAddress: outputTableAddress)
        if runs == 1 { stuck.setContract(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        return status
    }

    func runtimeVersion() -> String { inner.runtimeVersion() }

    func executionProvider() -> String { inner.executionProvider() }

    func close() {
        stuck?.countCloseAttempt()
        lock.lock()
        inner.close()
        lock.unlock()
        stuck?.countCloseFinished()
        stuck?.closed.signal()
    }
}

/// The one factory this test process registers. It arms the next glue it creates when a test asks; every other glue
/// is a plain pass-through to the production glue.
final class BlockingGlueFactory: NSObject, OnnxBridgeFactory, @unchecked Sendable {
    static let shared = BlockingGlueFactory()

    private let lock = NSLock()
    private var armed: StuckRun?
    private var made = 0

    /// How many glues the library has asked for since the last ``reset()``.
    var gluesMade: Int { lock.withLock { made } }

    /// The next glue created blocks from its second run on, until `stuck.letGo()`.
    func arm(_ stuck: StuckRun) { lock.withLock { armed = stuck } }

    func reset() { lock.withLock { armed = nil; made = 0 } }

    func create() -> OnnxBridge {
        let stuck: StuckRun? = lock.withLock {
            made += 1
            defer { armed = nil }
            return armed
        }
        return BlockingGlue(stuck: stuck)
    }
}
