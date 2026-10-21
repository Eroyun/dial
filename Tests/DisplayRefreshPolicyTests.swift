// Run without Xcode's XCTest or macro plugins:
// swiftc Sources/Dial/DisplayRefreshPolicy.swift Sources/Dial/MonitorCommandQueue.swift Tests/DisplayRefreshPolicyTests.swift -o /tmp/dial-policy-tests && /tmp/dial-policy-tests
import Foundation
@main
struct DisplayRefreshPolicyTests {
    static func main() {
        precondition(DisplayRefreshPolicy.shouldAdoptExternalMode(reason: .modeChange, isKnown: true, settling: false))
        precondition(!DisplayRefreshPolicy.shouldRestore(reason: .modeChange, isKnown: true, settling: false, affectedByReconnect: false))
        precondition(!DisplayRefreshPolicy.shouldRestore(reason: .inventory, isKnown: false, settling: false, affectedByReconnect: false))
        precondition(!DisplayRefreshPolicy.shouldAdoptExternalMode(reason: .inventory, isKnown: true, settling: false))
        precondition(!DisplayRefreshPolicy.shouldRebind(reason: .modeChange, isKnown: true, affectedByReconnect: false, alreadyRebound: false))

        for reason in [DisplayRefreshReason.topology, .wake] {
            precondition(!DisplayRefreshPolicy.shouldAdoptExternalMode(reason: reason, isKnown: true, settling: true))
            precondition(DisplayRefreshPolicy.shouldRestore(reason: reason, isKnown: true, settling: true, affectedByReconnect: true))
            precondition(DisplayRefreshPolicy.shouldRebind(reason: reason, isKnown: true, affectedByReconnect: true, alreadyRebound: false))
            precondition(DisplayRefreshPolicy.shouldRebind(reason: reason, isKnown: true, affectedByReconnect: true, alreadyRebound: true))
            precondition(!DisplayRefreshPolicy.shouldRebind(reason: reason, isKnown: true,
                                                           affectedByReconnect: true, alreadyRebound: true, ddcResponded: true))
        }
        precondition(!DisplayRefreshPolicy.shouldRestore(reason: .topology, isKnown: true, settling: true, affectedByReconnect: false))
        precondition(!DisplayRefreshPolicy.shouldRestore(reason: .wake, isKnown: true, settling: true,
                                                        affectedByReconnect: true, externalModeChangeObserved: true))
        precondition(!DisplayRefreshPolicy.shouldAdoptExternalMode(reason: .modeChange, isKnown: true, settling: true))
        precondition(DisplayRefreshPolicy.shouldRestore(reason: .modeChange, isKnown: false, settling: false, affectedByReconnect: false))
        precondition(!DisplayRefreshPolicy.shouldAdoptExternalMode(reason: .modeChange, isKnown: false, settling: false))

        // A UP topology callback must leave an unaffected, already-dimmed Philips alone.
        precondition(!DisplayRefreshPolicy.shouldReapplyDimming(reason: .topology,
            affectedByReconnect: false, modeChangeAffected: false))
        precondition(!DisplayRefreshPolicy.shouldReapplyDimming(reason: .modeChange,
            affectedByReconnect: false, modeChangeAffected: false)) // UP callback, Philips row
        precondition(DisplayRefreshPolicy.shouldReapplyDimming(reason: .modeChange,
            affectedByReconnect: false, modeChangeAffected: true)) // Philips callback
        precondition(DisplayRefreshPolicy.shouldReapplyDimming(reason: .inventory,
            affectedByReconnect: false, modeChangeAffected: true)) // mirror + Philips setMode
        precondition(!DisplayRefreshPolicy.shouldReapplyDimming(reason: .inventory,
            affectedByReconnect: false, modeChangeAffected: false)) // mirror + UP setMode
        precondition(DisplayRefreshPolicy.shouldReapplyDimming(reason: .topology,
            affectedByReconnect: true, modeChangeAffected: false))
        precondition(DisplayRefreshPolicy.shouldReapplyDimming(reason: .wake,
            affectedByReconnect: false, modeChangeAffected: false))

        let philips = DisplayIdentity(vendor: 16652, model: 50184, serial: 27225)
        let up = DisplayIdentity(vendor: 19083, model: 17732, serial: 1666187265)
        precondition(DisplayRefreshPolicy.mayWrite(captured: philips, current: philips, online: true))
        precondition(!DisplayRefreshPolicy.mayWrite(captured: philips, current: up, online: true))
        precondition(!DisplayRefreshPolicy.mayWrite(captured: philips, current: philips, online: false))
        let unknown = DisplayIdentity(vendor: 0, model: 0, serial: 0)
        let partial = DisplayIdentity(vendor: 16652, model: 0, serial: 0)
        precondition(!DisplayRefreshPolicy.mayWrite(captured: unknown, current: unknown, online: true))
        precondition(!DisplayRefreshPolicy.mayWrite(captured: partial, current: partial, online: true))
        let serialUnknown = DisplayIdentity(vendor: 16652, model: 50184, serial: 0)
        precondition(DisplayRefreshPolicy.mayWrite(captured: serialUnknown, current: serialUnknown, online: true))

        // The target changes while a write is queued behind an in-flight job. Checking
        // identity when the queued writer runs, not when set() is called, drops it.
        let lock = NSLock()
        var current = philips
        var writes = 0
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let queue = MonitorCommandQueue(label: "dial.policy.stale-id", callbackQueue: .global()) { _, _ in
            lock.lock()
            if DisplayRefreshPolicy.mayWrite(captured: philips, current: current, online: true) { writes += 1 }
            lock.unlock()
        }
        precondition(queue.enqueue({ _ = entered.signal(); release.wait() }))
        precondition(entered.wait(timeout: .now() + 2) == .success)
        precondition(queue.set(0x10, 50))
        lock.lock(); current = up; lock.unlock()
        precondition(queue.enqueue({ _ = done.signal() }))
        _ = release.signal()
        precondition(done.wait(timeout: .now() + 2) == .success)
        lock.lock(); let actualWrites = writes; lock.unlock()
        precondition(actualWrites == 0)
        queue.stopAndDrain {}

        // A queued Get VCP operation is also a bus write request. The same
        // execution-time guard must keep it from running after CG ID reuse.
        let readEntered = DispatchSemaphore(value: 0)
        let readRelease = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)
        let readQueue = MonitorCommandQueue(label: "dial.policy.stale-read", callbackQueue: .global()) { _, _ in }
        lock.lock(); current = philips; lock.unlock()
        precondition(readQueue.enqueue({ _ = readEntered.signal(); readRelease.wait() }))
        precondition(readEntered.wait(timeout: .now() + 2) == .success)
        var readIssued = false
        precondition(readQueue.read({ () -> Int? in
            lock.lock(); defer { lock.unlock() }
            guard DisplayRefreshPolicy.mayWrite(captured: philips, current: current, online: true) else { return nil }
            readIssued = true
            return 42
        }, completion: { value in precondition(value == nil); _ = readDone.signal() }))
        lock.lock(); current = up; lock.unlock()
        _ = readRelease.signal()
        precondition(readDone.wait(timeout: .now() + 2) == .success)
        precondition(!readIssued)
        readQueue.stopAndDrain {}

        precondition(DisplayRefreshPolicy.settleDelays.count == 3)
        precondition(DisplayRefreshPolicy.settleDelays == DisplayRefreshPolicy.settleDelays.sorted())
        precondition((DisplayRefreshPolicy.settleDelays.last ?? .infinity) <= 5)
        print("DisplayRefreshPolicy: all checks passed")
    }
}
