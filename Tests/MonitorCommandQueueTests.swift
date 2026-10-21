import Foundation

private final class Events {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private func wait(_ semaphore: DispatchSemaphore, _ label: String) {
    precondition(semaphore.wait(timeout: .now() + 3) == .success, "timed out: \(label)")
}

@main struct MonitorCommandQueueTests {
    static func main() {
        let callbacks = DispatchQueue(label: "monitor-command-test-callbacks")
        let events = Events()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let queue = MonitorCommandQueue(label: "monitor-command-test-coalesce",
                                        callbackQueue: callbacks) { vcp, value in
            events.add("write:\(vcp):\(value)")
            if value == 1 { entered.signal(); wait(release, "release first write") }
            if value == 3 { finished.signal() }
        }
        precondition(queue.set(0x10, 1))
        wait(entered, "first write started")
        precondition(queue.set(0x62, 1))
        precondition(queue.set(0x62, 2))
        precondition(queue.set(0x62, 3))
        release.signal()
        wait(finished, "coalesced write")
        precondition(events.snapshot == ["write:16:1", "write:98:3"])

        let stopEvents = Events()
        let stopEntered = DispatchSemaphore(value: 0)
        let stopRelease = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let stopQueue = MonitorCommandQueue(label: "monitor-command-test-drain",
                                            callbackQueue: callbacks) { vcp, value in
            stopEvents.add("write:\(vcp):\(value)")
            stopEntered.signal()
            wait(stopRelease, "release in-flight write")
        }
        precondition(stopQueue.set(0x10, 7))
        wait(stopEntered, "in-flight write started")
        precondition(stopQueue.set(0x62, 8))
        precondition(stopQueue.read({ () -> Int? in
            stopEvents.add("read-started")
            return 9
        }, completion: { value in
            stopEvents.add(value == nil ? "read-cancelled" : "read-completed")
        }))
        precondition(stopQueue.enqueue({ stopEvents.add("job-started") },
                                     onCancel: { stopEvents.add("job-cancelled") }))
        stopQueue.stopAndDrain {
            stopEvents.add("drained")
            drained.signal()
        }
        precondition(!stopQueue.set(0x10, 10))
        precondition(!stopQueue.read({ () -> Int? in 10 }, completion: { value in
            stopEvents.add(value == nil ? "poststop-refused" : "poststop-ran")
        }))
        precondition(drained.wait(timeout: .now() + 0.05) == .timedOut,
                     "drain completed while writer was still in flight")
        stopRelease.signal()
        wait(drained, "drain after in-flight write")
        let observed = stopEvents.snapshot
        precondition(observed.contains("read-cancelled"))
        precondition(observed.contains("job-cancelled"))
        precondition(!observed.contains("read-started") && !observed.contains("job-started"))
        precondition(!observed.contains("write:98:8"))
        precondition(observed.first == "write:16:7")
        precondition(observed.firstIndex(of: "read-cancelled")! < observed.firstIndex(of: "drained")!)
        precondition(observed.firstIndex(of: "job-cancelled")! < observed.firstIndex(of: "drained")!)
        let refused = DispatchSemaphore(value: 0)
        callbacks.async { refused.signal() }
        wait(refused, "poststop completion")
        precondition(stopEvents.snapshot.contains("poststop-refused"))
    }
}
