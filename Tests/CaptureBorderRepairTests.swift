import Foundation

@main
struct CaptureBorderRepairTests {
    private static func check(_ condition: Bool, _ message: String,
                              file: StaticString = #file, line: UInt = #line) {
        precondition(condition, message, file: file, line: line)
    }

    static func main() throws {
        let width = 96
        let height = 48
        let dark: [UInt8] = [18, 20, 22]
        let light: [UInt8] = [220, 224, 228]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
        func put(_ x: Int, _ y: Int, _ color: [UInt8], _ alpha: UInt8) {
            let i = index(x, y)
            bytes[i] = color[0]; bytes[i + 1] = color[1]
            bytes[i + 2] = color[2]; bytes[i + 3] = alpha
        }
        func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
            Array(pixels[index(x, y)..<(index(x, y) + 4)])
        }
        for y in 0..<height {
            for x in 0..<width { put(x, y, x < width / 2 ? dark : light, 255) }
        }

        // Rounded outer corners with premultiplied translucent antialiasing.
        for x in 0..<5 { put(x, 0, [0, 0, 0], 0) }
        put(5, 0, [100, 50, 25], 128)
        for x in 92..<width { put(x, 0, [0, 0, 0], 0) }
        put(91, 0, [30, 60, 90], 128)
        for x in 0..<24 { put(x, 47, [0, 0, 0], 0) }

        // Opaque edge ink and transparent interior remain byte-for-byte intact.
        put(0, 10, [240, 240, 240], 255)
        put(1, 10, [0, 0, 0], 0)
        put(40, 24, [0, 0, 0], 0)
        put(20, 35, [0, 0, 0], 0)

        // Mixed adjacent colors do not identify a reliable backing color.
        for y in 30...34 {
            for x in 4..<20 {
                let color: [UInt8] = x.isMultiple(of: 2) ? [0, 0, 0] : [255, 255, 255]
                put(x, y, color, 255)
            }
        }
        for x in 0..<4 { put(x, 32, [0, 0, 0], 0) }

        // A missing run wider than the 24-pixel cap is never invented.
        for x in 0..<25 { put(x, 46, [0, 0, 0], 0) }

        let input = try ScrollCaptureFrame(width: width, height: height, pixels: bytes)
        let output = CaptureBorderRepair.repair(input)
        check(output.width == width && output.height == height, "Frame dimensions changed")
        check(pixel(output.pixels, 0, 0) == dark + [255], "Dark left corner was not filled")
        check(pixel(output.pixels, 5, 0) == [109, 60, 36, 255], "Premultiplied left edge was not composited")
        check(pixel(output.pixels, 95, 0) == light + [255], "Light right corner was not filled")
        check(pixel(output.pixels, 91, 0) == [140, 172, 204, 255], "Premultiplied right edge was not composited")
        check(pixel(output.pixels, 23, 47) == dark + [255], "The 24-pixel corner cap was not filled")
        check(pixel(output.pixels, 0, 46) == [0, 0, 0, 0], "A wider transparent area was fabricated")
        check(pixel(output.pixels, 0, 32) == [0, 0, 0, 0], "An ambiguous background was fabricated")
        check(pixel(output.pixels, 1, 10) == [0, 0, 0, 0], "Transparency behind opaque edge ink changed")
        check(pixel(output.pixels, 40, 24) == [0, 0, 0, 0] && pixel(output.pixels, 20, 35) == [0, 0, 0, 0],
              "Interior transparency changed")
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] == 255 {
            check(Array(output.pixels[i..<(i + 4)]) == Array(bytes[i..<(i + 4)]), "Opaque source content changed")
        }
        check(CaptureBorderRepair.repair(output).pixels == output.pixels, "Repair must be idempotent")

        let opaque = try ScrollCaptureFrame(width: width, height: height,
                                            pixels: [UInt8](repeating: 255, count: width * height * 4))
        check(CaptureBorderRepair.repair(opaque).pixels == opaque.pixels, "Opaque capture changed")
        print("Capture border repair: narrow corners, premultiplied alpha, distinct backgrounds, and conservative skips passed")
    }
}
