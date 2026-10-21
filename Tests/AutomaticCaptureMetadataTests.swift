import Foundation
import AppKit

private final class FixtureEndpoint: NSObject {
    let pids: [Int32]
    init(_ pids: [Int32]) {
        self.pids = pids
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(query(_:)), name: Notification.Name("io.github.eroyun.dial.capture.scroll.status"), object: nil)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    @objc func query(_ note: Notification) {
        guard let nonce = note.object as? String, UUID(uuidString: nonce) != nil else { return }
        for pid in pids {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.eroyun.dial.capture.scroll.reply." + nonce), object: nil,
                userInfo: ["respondingPID": NSNumber(value: pid), "sessionID": UUID().uuidString, "phase": "fixture_only"], deliverImmediately: true)
        }
    }
}

@main enum AutomaticCaptureMetadataTests {
    static func main() throws {
        // Only fixture IDs pass the injected process matcher; these probes never
        // issue capture, scroll, stop, cancel or permission requests.
        do {
            let endpoint = FixtureEndpoint([987001])
            let reports = CaptureStatusProbe(acceptsProcess: { $0 == 987001 }).readReports()
            precondition(reports.count == 1 && reports[0]["phase"] as? String == "fixture_only")
            withExtendedLifetime(endpoint) {}
        }
        do {
            let endpoint = FixtureEndpoint([987001, 987002])
            let reports = CaptureStatusProbe(acceptsProcess: { [987001, 987002].contains($0) }).readReports()
            precondition(reports.count == 2, "All matching replies are collected; first reply cannot hide ambiguity")
            withExtendedLifetime(endpoint) {}
        }
        do {
            let endpoint = FixtureEndpoint([987001])
            precondition(CaptureStatusProbe(acceptsProcess: { _ in false }).readReports().isEmpty)
            withExtendedLifetime(endpoint) {}
        }
        let pixels = 512 * 256
        let base = try ScrollCaptureFrame(width: 512, height: 256, pixels: Array(repeating: [UInt8(0), 20, 200, 255], count: pixels).flatMap { $0 })
        let greenChanged = try ScrollCaptureFrame(width: 512, height: 256, pixels: Array(repeating: [UInt8(0), 80, 200, 255], count: pixels).flatMap { $0 })
        precondition(!ScrollScreenshot.appearsStable(base, greenChanged), "Equal red channels cannot conceal content movement")
        var caretPixels = base.pixels
        for p in 0..<8 { caretPixels[p * 4 + 1] = 255 }
        let caret = try ScrollCaptureFrame(width: 512, height: 256, pixels: caretPixels)
        precondition(ScrollScreenshot.appearsStable(base, caret), "A small caret cannot prevent top settling forever")
        print("Automatic capture metadata: fresh fixture replies, ambiguity, process filter and RGB stability passed")
    }
}
