import Foundation
import IOKit
import IOKit.hid

// Registry notifications only: this never opens a HID device or sends reports.
// The owning keyboard window starts and stops it on the main run loop.
final class AULAConnectionObserver {
    private var port: IONotificationPortRef?
    private var source: CFRunLoopSource?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var changed: (() -> Void)?

    func start(changed: @escaping () -> Void) {
        stop()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        self.changed = changed
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            stop()
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let observer = Unmanaged<AULAConnectionObserver>.fromOpaque(context).takeUnretainedValue()
            if observer.drain(iterator) { observer.scheduleChange() }
        }
        // Each call consumes its matching dictionary. Drain once to arm each
        // notification; the caller already performs the initial status refresh.
        guard IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching(), callback, context, &added) == KERN_SUCCESS else {
            stop()
            return
        }
        _ = drain(added)
        guard IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching(), callback, context, &removed) == KERN_SUCCESS else {
            stop()
            return
        }
        _ = drain(removed)
    }

    func stop() {
        generation &+= 1
        pending?.cancel()
        pending = nil
        changed = nil
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    deinit { stop() }

    private func matching() -> CFDictionary? {
        guard let dictionary = IOServiceMatching(kIOHIDDeviceKey) else { return nil }
        let match = dictionary as NSMutableDictionary
        match[kIOHIDVendorIDKey] = 0x0C45
        match[kIOHIDProductIDKey] = 0x800A
        return dictionary
    }

    private func drain(_ iterator: io_iterator_t) -> Bool {
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            found = true
            IOObjectRelease(service)
        }
        return found
    }

    private func scheduleChange() {
        pending?.cancel()
        generation &+= 1
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pending = nil
            self.changed?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

// Automatic single-device selection is deliberately not an explicit choice.
enum AULAConnectionSelection {
    static func resolve(ids: [String], selected: String, explicit: Bool) -> (id: String, explicit: Bool) {
        if explicit && ids.contains(selected) { return (selected, true) }
        if ids.count == 1 { return (ids[0], false) }
        return ("", false)
    }
}

struct AULAConnectionRefreshState {
    private(set) var active = false
    private var pending = false

    mutating func open() { active = true }
    mutating func close() { active = false; pending = false }

    mutating func request(busy: Bool) -> Bool {
        guard !busy else {
            if active { pending = true }
            return false
        }
        return true
    }

    mutating func childExited() -> Bool {
        let refresh = active && pending
        pending = false
        return refresh
    }
}
