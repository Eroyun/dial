import Foundation

/// Fills only narrow transparent runs touching the left or right capture edge.
/// ScrollCaptureFrame stores premultiplied RGBA8 pixels from CGContext; opaque
/// pixels have the same representation in the stitcher's exported image.
enum CaptureBorderRepair {
    private static let maximumEdgeWidth = 24
    private static let backgroundDepth = 16
    private static let verticalRadius = 2

    static func repair(_ frame: ScrollCaptureFrame) -> ScrollCaptureFrame {
        guard frame.width >= maximumEdgeWidth * 2 + backgroundDepth,
              frame.height > 0 else { return frame }
        var pixels = frame.pixels
        var changed = false

        for y in 0..<frame.height {
            for fromLeft in [true, false] {
                let edgeX = fromLeft ? 0 : frame.width - 1
                guard alpha(frame.pixels, width: frame.width, x: edgeX, y: y) < 255 else { continue }
                var run = 0
                while run < maximumEdgeWidth {
                    let x = fromLeft ? run : frame.width - 1 - run
                    if alpha(frame.pixels, width: frame.width, x: x, y: y) == 255 { break }
                    run += 1
                }
                // A wider missing area has no local background authority.
                let nextX = fromLeft ? run : frame.width - 1 - run
                guard run > 0,
                      alpha(frame.pixels, width: frame.width, x: nextX, y: y) == 255,
                      let background = dominantBackground(frame, row: y, run: run,
                                                          fromLeft: fromLeft) else { continue }

                for distance in 0..<run {
                    let x = fromLeft ? distance : frame.width - 1 - distance
                    let index = (y * frame.width + x) * 4
                    let opacity = Int(frame.pixels[index + 3])
                    for channel in 0..<3 {
                        let premultiplied = min(opacity, Int(frame.pixels[index + channel]))
                        let backing = Int(background[channel]) * (255 - opacity)
                        pixels[index + channel] = UInt8(min(255, premultiplied + (backing + 127) / 255))
                    }
                    pixels[index + 3] = 255
                    changed = true
                }
            }
        }

        guard changed else { return frame }
        // Width, height, and buffer length are inherited unchanged from an
        // already validated frame; only existing pixel bytes were replaced.
        return try! ScrollCaptureFrame(width: frame.width, height: frame.height, pixels: pixels)
    }

    private static func alpha(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> UInt8 {
        pixels[(y * width + x) * 4 + 3]
    }

    private static func dominantBackground(_ frame: ScrollCaptureFrame, row: Int,
                                           run: Int, fromLeft: Bool) -> [UInt8]? {
        var samples: [UInt32] = []
        samples.reserveCapacity(backgroundDepth * (verticalRadius * 2 + 1))
        let firstY = max(0, row - verticalRadius)
        let lastY = min(frame.height - 1, row + verticalRadius)
        for y in firstY...lastY {
            for distance in run..<(run + backgroundDepth) {
                let x = fromLeft ? distance : frame.width - 1 - distance
                let index = (y * frame.width + x) * 4
                guard frame.pixels[index + 3] == 255 else { continue }
                let color = UInt32(frame.pixels[index]) << 16 |
                    UInt32(frame.pixels[index + 1]) << 8 |
                    UInt32(frame.pixels[index + 2])
                samples.append(color)
            }
        }
        guard samples.count >= 12 else { return nil }

        // Choose the most common exact color, then allow minor raster noise.
        // A gradient, image, text stroke, or mixed sidebar cannot establish a
        // dominant local background and is left transparent for the caller.
        var frequencies: [UInt32: Int] = [:]
        var mode = samples[0]
        var modeCount = 0
        for color in samples {
            frequencies[color, default: 0] += 1
            if frequencies[color]! > modeCount {
                mode = color
                modeCount = frequencies[color]!
            }
        }
        let agreeing = samples.filter { sample in
            [16, 8, 0].allSatisfy { shift in
                abs(Int((sample >> shift) & 0xff) - Int((mode >> shift) & 0xff)) <= 6
            }
        }.count
        guard agreeing * 4 >= samples.count * 3 else { return nil }
        return [UInt8((mode >> 16) & 0xff), UInt8((mode >> 8) & 0xff), UInt8(mode & 0xff)]
    }
}
