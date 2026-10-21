import Foundation
import CoreGraphics

@main enum ScrollingContentPreservationTests {
    static let width = 240, height = 240
    static func color(_ x: Int, _ y: Int) -> [UInt8] {
        var v = UInt32(truncatingIfNeeded: x * 1031 + y * 79919 + 47)
        v ^= v << 13; v ^= v >> 17; v ^= v << 5
        return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), 255]
    }
    static func page(_ offset: Int) throws -> ScrollCaptureFrame {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let documentY = y - 24 + offset
                if y < 24 || y >= height - 20 { pixels += [220, 220, 220, 255] }
                else if (80..<160).contains(x) || ((24..<216).contains(x) && (0..<30).contains(documentY)) {
                    pixels += color(x, documentY)
                } else { pixels += [255, 255, 255, 255] }
            }
        }
        return try ScrollCaptureFrame(width: width, height: height, pixels: pixels)
    }
    static func main() throws {
        var failures = 0
        let wide = ScrollingImageStitcher(trimStationaryColumns: true)
        let first = try page(0), second = try page(40)
        precondition(wide.append(first) == .first)
        precondition(wide.append(second) == .appended(rows: 40))
        guard let image = wide.image() else { fatalError("Missing image") }
        if image.width != 192 { print("FAIL: first-viewport illustration was cropped: \(image.width), expected 192"); failures += 1 }
        else {
            let data = image.dataProvider!.data!
            let bytes = CFDataGetBytePtr(data)!
            for x in 0..<image.width {
                let i = 24 * image.bytesPerRow + x * 4
                precondition(Array(UnsafeBufferPointer(start: bytes + i, count: 4)) == color(x + 24, 0),
                             "Every illustration column must survive export")
            }
        }
        let blank = try ScrollCaptureFrame(width: width, height: height,
                                          pixels: [UInt8](repeating: 255, count: width * height * 4))
        var footnotePixels = blank.pixels
        for y in 225..<227 { for x in 111..<114 {
            let i = (y * width + x) * 4
            footnotePixels[i] = 0; footnotePixels[i + 1] = 0; footnotePixels[i + 2] = 0
        } }
        let sparse = ScrollingImageStitcher()
        precondition(sparse.append(blank) == .first)
        let result = sparse.append(try ScrollCaptureFrame(width: width, height: height, pixels: footnotePixels))
        if case .rejected = result { }
        else { print("FAIL: new sparse content must be inconclusive, not stationary: \(result)"); failures += 1 }
        if failures > 0 { exit(1) }
        print("PASS: wide first-viewport content and sparse final content preserved or rejected truthfully")
    }
}
