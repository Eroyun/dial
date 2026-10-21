import Foundation

/// Serial, hardware-independent admission queue for one monitor's DDC commands.
/// `stopAndDrain` prevents new work and waits for an already-started command without
/// blocking its caller. A read queued behind a command is cancelled with `nil`.
final class MonitorCommandQueue {
    private enum Job {
        case write(UInt8, UInt16)
        case task(run: () -> Void, cancel: () -> Void)

        var cancellation: (() -> Void)? {
            if case .task(_, let cancel) = self { return cancel }
            return nil
        }
    }

    private let worker: DispatchQueue
    private let callbacks: DispatchQueue
    private let writer: (UInt8, UInt16) -> Void
    private let lock = NSLock()
    private var pending: [Job] = []
    private var workerScheduled = false
    private var inFlight = false
    private var stopped = false
    private var pendingCancellations: [() -> Void] = []
    private var drainCallbacks: [() -> Void] = []
    private let maxPending = 256

    init(label: String, callbackQueue: DispatchQueue = .main,
         writer: @escaping (UInt8, UInt16) -> Void) {
        worker = DispatchQueue(label: label, qos: .userInitiated)
        callbacks = callbackQueue
        self.writer = writer
    }

    /// Coalesces a not-yet-started write of the same VCP within the current write segment.
    /// A queued read/job is an ordering barrier; it will observe earlier writes first.
    @discardableResult
    func set(_ vcp: UInt8, _ value: UInt16) -> Bool {
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        for index in pending.indices.reversed() {
            switch pending[index] {
            case .task:
                break
            case .write(let previous, _):
                if previous == vcp {
                    pending[index] = .write(vcp, value)
                    lock.unlock()
                    return true
                }
                continue
            }
            break
        }
        guard pending.count < maxPending else { lock.unlock(); return false }
        pending.append(.write(vcp, value))
        scheduleIfNeededLocked()
        lock.unlock()
        return true
    }

    /// Returns false after stop or when the bounded queue is full; completion(nil) is
    /// delivered asynchronously in either case. Started reads may finish after stop.
    @discardableResult
    func read<Value>(_ operation: @escaping () -> Value?,
                     completion: @escaping (Value?) -> Void) -> Bool {
        enqueue({ [callbacks] in
            let value = operation()
            callbacks.async { completion(value) }
        }, onCancel: { completion(nil) })
    }

    /// Generic serial job for callers that need more than a VCP read. Cancellation is
    /// asynchronous on callbackQueue; no job is started after stop has acquired the lock.
    @discardableResult
    func enqueue(_ operation: @escaping () -> Void,
                 onCancel: @escaping () -> Void = {}) -> Bool {
        lock.lock()
        guard !stopped, pending.count < maxPending else {
            lock.unlock()
            callbacks.async(execute: onCancel)
            return false
        }
        pending.append(.task(run: operation, cancel: onCancel))
        scheduleIfNeededLocked()
        lock.unlock()
        return true
    }

    /// Clears commands not yet started, rejects future commands, and calls completion
    /// asynchronously on callbackQueue after the current command returns. Idempotent.
    func stopAndDrain(_ completion: @escaping () -> Void) {
        lock.lock()
        stopped = true
        pendingCancellations.append(contentsOf: pending.compactMap(\.cancellation))
        pending.removeAll()
        if inFlight {
            drainCallbacks.append(completion)
            lock.unlock()
        } else {
            let cancelled = pendingCancellations
            pendingCancellations.removeAll()
            lock.unlock()
            for cancel in cancelled { callbacks.async(execute: cancel) }
            callbacks.async(execute: completion)
        }
    }

    private func scheduleIfNeededLocked() {
        guard !inFlight, !workerScheduled, !pending.isEmpty else { return }
        workerScheduled = true
        worker.async { [self] in runNext() }
    }

    private func runNext() {
        lock.lock()
        workerScheduled = false
        guard !stopped, !pending.isEmpty else { lock.unlock(); return }
        let job = pending.removeFirst()
        inFlight = true
        lock.unlock()

        switch job {
        case .write(let vcp, let value): writer(vcp, value)
        case .task(let run, _): run()
        }

        lock.lock()
        inFlight = false
        let cancelled = stopped ? pendingCancellations : []
        let drained = stopped ? drainCallbacks : []
        if stopped { pendingCancellations.removeAll(); drainCallbacks.removeAll() }
        else { scheduleIfNeededLocked() }
        lock.unlock()
        for cancel in cancelled { callbacks.async(execute: cancel) }
        for completion in drained { callbacks.async(execute: completion) }
    }
}
