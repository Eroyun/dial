import CDDC
import CoreGraphics
import Foundation
import IOKit

/// DDC/CI over the display's I2C bus (Apple silicon, via IOAVService).
/// All calls block for tens of milliseconds; call them off the main thread.
final class DDC {
    enum VCP: UInt8 {
        case brightness = 0x10
        case volume = 0x62
    }

    private let service: IOAVService
    private let lock = NSLock()

    init?(ioService: io_service_t) {
        guard let service = IOAVServiceCreateWithService(kCFAllocatorDefault, ioService) else { return nil }
        self.service = service
    }

    @discardableResult
    func write(_ vcp: VCP, _ value: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var packet: [UInt8] = [0x84, 0x03, vcp.rawValue, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ 0x51, ^)
        var ok = false
        for _ in 0..<2 {
            usleep(10_000)
            if IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
        }
        return ok
    }

    /// Returns nil when the display does not answer or does not support the control.
    func read(_ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        lock.lock(); defer { lock.unlock() }
        var packet: [UInt8] = [0x82, 0x01, vcp.rawValue, 0]
        packet[3] = packet[0..<3].reduce(0x6E ^ 0x51, ^)
        for _ in 0..<4 {
            usleep(10_000)
            guard IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            if ProcessInfo.processInfo.environment["DIAL_DEBUG"] != nil { print("vcp \(vcp.rawValue) reply", reply.map { String(format: "%02X", $0) }.joined(separator: " ")) }
            // 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
            guard reply[2] == 0x02, reply[4] == vcp.rawValue else { continue }
            guard reply[3] == 0 else { return nil }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            guard max > 0, current <= max else { continue }
            return (current, max)
        }
        return nil
    }
}

/// Coalesces rapid slider changes so the I2C bus only ever sees the latest value.
final class DDCWriter {
    private let ddc: DDC
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [DDC.VCP: UInt16] = [:]
    private var draining = false

    init(ddc: DDC, label: String) {
        self.ddc = ddc
        self.queue = DispatchQueue(label: "dial.ddc.\(label)", qos: .userInitiated)
    }

    func set(_ vcp: DDC.VCP, _ value: UInt16) {
        lock.lock()
        pending[vcp] = value
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func read(_ vcp: DDC.VCP, completion: @escaping ((current: UInt16, max: UInt16)?) -> Void) {
        queue.async { completion(self.ddc.read(vcp)) }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (vcp, value) = pending.popFirst() else {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            ddc.write(vcp, value)
        }
    }
}

/// Finds the I2C service behind each external display by walking the IO registry:
/// a framebuffer carrying `DisplayAttributes` is followed by its `DCPAVServiceProxy`.
enum AVServiceLocator {
    struct Match {
        let vendor: Int
        let product: Int
        let serial: Int
        let name: String
        let ddc: DDC
    }

    static func externalServices() -> [Match] {
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var matches: [Match] = []
        var lastAttributes: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let attrs = property(entry, "DisplayAttributes") as? [String: Any] {
                lastAttributes = attrs["ProductAttributes"] as? [String: Any]
                continue
            }
            guard className(entry) == "DCPAVServiceProxy" else { continue }
            let location = property(entry, "Location") as? String
            defer { lastAttributes = nil }
            guard location == "External", let attrs = lastAttributes, let ddc = DDC(ioService: entry) else { continue }
            matches.append(Match(
                vendor: attrs["LegacyManufacturerID"] as? Int ?? 0,
                product: attrs["ProductID"] as? Int ?? 0,
                serial: attrs["SerialNumber"] as? Int ?? 0,
                name: attrs["ProductName"] as? String ?? "",
                ddc: ddc
            ))
        }
        return matches
    }

    static func match(for display: CGDirectDisplayID, in services: [Match]) -> Match? {
        let vendor = Int(CGDisplayVendorNumber(display))
        let product = Int(CGDisplayModelNumber(display))
        let serial = Int(CGDisplaySerialNumber(display))
        let candidates = services.filter { $0.vendor == vendor && $0.product == product }
        return candidates.first { serial != 0 && $0.serial == serial } ?? candidates.first
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func className(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buffer)
        return String(cString: buffer)
    }
}
