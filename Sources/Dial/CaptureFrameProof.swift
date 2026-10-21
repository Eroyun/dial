import Foundation
import CoreGraphics
import ImageIO

/// Opt-in development evidence, separate from normal screenshots and settings.
/// Only an explicit public fixture can write two lossless assembler inputs.
final class CaptureFrameProof {
    static let environmentKey = "DIAL_SCROLL_PROOF_DIRECTORY"
    private let directory: URL
    private(set) var frameCount = 0
    private(set) var issue = ""

    init?(directoryPath: String?, publicFixture: Bool) {
        guard publicFixture, let directoryPath, !directoryPath.isEmpty else { return nil }
        let supplied = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        let resolved = supplied.resolvingSymlinksInPath()
        guard supplied.path == resolved.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              (try? FileManager.default.contentsOfDirectory(atPath: resolved.path))?.isEmpty == true else { return nil }
        directory = resolved
    }

    func record(_ frame: ScrollCaptureFrame, label: String, metadata: [String: String]) {
        guard frameCount < 2, ["reference", "observation"].contains(label), issue.isEmpty,
              frame.width <= 8_000_000 / frame.height else { return }
        let expectedLabel = frameCount == 0 ? "reference" : "observation"
        guard label == expectedLabel else { return }
        do {
            guard let provider = CGDataProvider(data: Data(frame.pixels) as CFData),
                  let image = CGImage(width: frame.width, height: frame.height,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                issue = "image_unavailable"; return
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
                issue = "encoder_unavailable"; return
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { issue = "encoding_failed"; return }
            var receipt = metadata
            receipt["source"] = "Dial ScreenCaptureKit assembler input after CaptureBorderRepair"
            receipt["format"] = "lossless PNG"
            receipt["width"] = String(frame.width); receipt["height"] = String(frame.height)
            receipt["observedUTC"] = ISO8601DateFormatter().string(from: Date())
            try (encoded as Data).write(to: directory.appendingPathComponent(label + ".png"), options: .withoutOverwriting)
            let json = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            try json.write(to: directory.appendingPathComponent(label + ".json"), options: .withoutOverwriting)
            frameCount += 1
        } catch { issue = "write_failed" }
    }
}
