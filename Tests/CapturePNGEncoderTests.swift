import CoreGraphics
import Foundation
import ImageIO

@main enum CapturePNGEncoderTests {
    static func main() throws {
        let frame = try ScrollCaptureFrame(width: 16, height: 16,
                                           pixels: [UInt8](repeating: 255, count: 16 * 16 * 4))
        let store = try CaptureRowStore(width: 16, maximumPixels: 1024)
        precondition(store.seed(frame: frame))
        let image = store.image()!
        let cancellation = CapturePNGEncoder.Cancellation()
        let png = CapturePNGEncoder.encode(image, cancellation: cancellation)!
        precondition(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(decoded.width == 16 && decoded.height == 16)
        cancellation.cancel()
        precondition(CapturePNGEncoder.encode(image, cancellation: cancellation) == nil)

        // Exercise the actual mapped output and native PNG encoder beyond both
        // former product bounds (40M pixels and 20k rows), without retaining
        // hundreds of source viewports in memory.
        let large = try CaptureRowStore(width: 512, maximumPixels: 52_000_000)
        let block = try ScrollCaptureFrame(width: 512, height: 2_000,
                                           pixels: [UInt8](repeating: 255, count: 512 * 2_000 * 4))
        precondition(large.seed(frame: block))
        for _ in 1..<50 { precondition(large.append(frame: block, rows: 0..<2_000, trimming: 0)) }
        let largeImage = large.image()!
        precondition(largeImage.width == 512 && largeImage.height == 100_000)
        let largePNG = CapturePNGEncoder.encode(largeImage, cancellation: .init())!
        let largeSource = CGImageSourceCreateWithData(largePNG as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(largeSource, 0, nil)! as NSDictionary
        precondition(properties[kCGImagePropertyPixelWidth] as? Int == 512)
        precondition(properties[kCGImagePropertyPixelHeight] as? Int == 100_000)
        print("Native PNG: round-trip, cancellation, and disk-backed 51.2M-pixel / 100,000-row output passed (synthetic pixels)")
    }
}
