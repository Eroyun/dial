import AppKit

@main
struct CaptureImageEditorTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
    static func image(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            bytes[i] = UInt8(y); bytes[i + 1] = UInt8(x); bytes[i + 2] = 20
        }}
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let i = y * image.bytesPerRow + x * 4
        return Array(data[i..<(i + 4)])
    }
    static func main() async throws {
        let source = image(width: 80, height: 100)
        let unchanged = try CaptureImageRenderer.render(source: source)
        check(unchanged === source, "Empty edit must reuse the original image")
        let full = try CaptureImageRenderer.render(source: source, crop: CGRect(x: 0, y: 0, width: 80, height: 100))
        check(full === source, "Full crop must reuse the original image")
        let area = CGRect(x: 10, y: 20, width: 40, height: 50)
        let cropped = try CaptureImageRenderer.render(source: source, crop: area)
        check(cropped.width == 40 && cropped.height == 50, "Crop dimensions")
        check(pixel(cropped, 0, 0) == [20, 10, 20, 255], "Top row must come from source row 20")
        check(pixel(cropped, 39, 49) == [69, 49, 20, 255], "Last crop row must retain exact source pixels")
        let normalized = try CaptureImageRenderer.normalizedCrop(CGRect(x: 60.8, y: 90.4, width: -70, height: -100), width: 80, height: 100)
        check(normalized == CGRect(x: 0, y: 0, width: 61, height: 91), "Normalize reversed crop and clamp")
        for invalid in [CGRect.zero, CGRect(x: 200, y: 200, width: 10, height: 10), CGRect(x: CGFloat.nan, y: 0, width: 2, height: 2)] {
            do { _ = try CaptureImageRenderer.render(source: source, crop: invalid); preconditionFailure("Invalid crop accepted") }
            catch CaptureImageRenderer.RenderError.invalidCrop {}
        }
        let annotation = CaptureImageAnnotation(tool: .box, start: CGPoint(x: 20, y: 30), end: CGPoint(x: 35, y: 40), color: .red, lineWidth: 2)
        let annotated = try CaptureImageRenderer.render(source: source, crop: area, annotations: [annotation])
        check(pixel(annotated, 10, 10)[0] > 240 && pixel(annotated, 10, 10)[1] < 20, "Annotation must use original top-down coordinates after crop")
        check(pixel(annotated, 0, 0) == [20, 10, 20, 255], "Annotation must not flip the original image")
        check(pixel(annotated, 39, 49) == [69, 49, 20, 255], "Annotation must leave distant pixels unchanged")
        let outside = CaptureImageAnnotation(tool: .box, start: CGPoint(x: 60, y: 80), end: CGPoint(x: 70, y: 90), color: .red)
        let outsideResult = try CaptureImageRenderer.render(source: source, crop: area, annotations: [outside])
        check(pixel(outsideResult, 0, 0) == pixel(cropped, 0, 0) && pixel(outsideResult, 39, 49) == pixel(cropped, 39, 49), "Outside annotation must be clipped")
        let arrow = CaptureImageAnnotation(tool: .arrow, start: CGPoint(x: 15, y: 25), end: CGPoint(x: 30, y: 35), color: .red, lineWidth: 2)
        let arrowResult = try CaptureImageRenderer.render(source: source, crop: area, annotations: [arrow])
        check(pixel(arrowResult, 20, 15)[0] > 240, "Arrow tip must be at selected original pixel")
        let note = CaptureImageAnnotation(tool: .text, start: CGPoint(x: 15, y: 25), end: CGPoint(x: 15, y: 25), text: "Hi", color: .red, lineWidth: 1)
        let textResult = try CaptureImageRenderer.render(source: source, crop: area, annotations: [note])
        var textInk = 0
        for y in 5..<25 { for x in 5..<30 {
            let color = pixel(textResult, x, y)
            if color[0] > 200 && color[1] < 40 { textInk += 1 }
        }}
        check(textInk > 5, "Text must render near its top-down anchor")
        check(pixel(textResult, 39, 49) == [69, 49, 20, 255], "Text must not change distant pixels")
        let alphaBytes: [UInt8] = [0, 0, 0, 0, 40, 20, 10, 128, 20, 30, 40, 255, 0, 0, 0, 0]
        let transparent = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: CGDataProvider(data: Data(alphaBytes) as CFData)!, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)!
        let alphaResult = try CaptureImageRenderer.render(source: transparent, annotations: [outside])
        check(pixel(alphaResult, 0, 0) == [0, 0, 0, 0] && pixel(alphaResult, 1, 1) == [0, 0, 0, 0], "Redraw must retain transparent corners")
        check(pixel(alphaResult, 1, 0)[3] == 128, "Redraw must retain partial alpha")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CaptureImageRenderer.render(source: source, crop: area, annotations: [note])
        }
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelled edit must not allocate or return an image")
        } catch is CancellationError { }
        print("Capture image editor: exact crop rows, no-op identity, coordinate normalization, invalid crops, annotation orientation and clipping passed")
    }
}
