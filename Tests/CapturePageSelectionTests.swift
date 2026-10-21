import CoreGraphics

@main
enum CapturePageSelectionTests {
    static func main() {
        let window = CGRect(x: -1920, y: 30, width: 1920, height: 1000)
        let crop = CGRect(x: -1500, y: 100, width: 1000, height: 800)
        precondition(CapturePageSelection.contentPoint(rect: crop, windowBounds: window) == CGPoint(x: -1000, y: 500))
        precondition(CapturePageSelection.contentPoint(rect: CGRect(x: -500, y: 900, width: -1000, height: -800), windowBounds: window) == CGPoint(x: -1000, y: 500))
        precondition(CapturePageSelection.contentPoint(rect: CGRect(x: -100, y: 900, width: 300, height: 300), windowBounds: window) == CGPoint(x: -50, y: 965))
        precondition(CapturePageSelection.contentPoint(rect: .zero, windowBounds: window) == nil)
        precondition(CapturePageSelection.contentPoint(rect: CGRect(x: CGFloat.infinity, y: 0, width: 300, height: 300), windowBounds: window) == nil)
        print("Page selection: crop center, drag direction, display translation, clipping, and invalid geometry checks passed")
    }
}
