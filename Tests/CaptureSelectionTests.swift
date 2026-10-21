import CoreGraphics

@main
enum CaptureSelectionTests {
    static func main() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

        check(CaptureSelectionGeometry.resolve(
            anchor: CGPoint(x: 300, y: 400),
            end: CGPoint(x: 300, y: 400),
            maximumExcursion: 0,
            bounds: bounds
        ) == bounds, "A click selects the full display")

        check(CaptureSelectionGeometry.resolve(
            anchor: CGPoint(x: 300, y: 400),
            end: CGPoint(x: 302, y: 401),
            maximumExcursion: 3,
            bounds: bounds
        ) == bounds, "Tiny pointer jitter still counts as a click")

        check(CaptureSelectionGeometry.resolve(
            anchor: CGPoint(x: 300, y: 400),
            end: CGPoint(x: 301, y: 400),
            maximumExcursion: 12,
            bounds: bounds
        ) == nil, "A deliberate small drag that returns to its start is rejected")

        check(CaptureSelectionGeometry.resolve(
            anchor: CGPoint(x: 300, y: 400),
            end: CGPoint(x: 100, y: 100),
            maximumExcursion: 361,
            bounds: bounds
        ) == CGRect(x: 100, y: 100, width: 200, height: 300), "Reverse-direction drags normalize")

        check(CaptureSelectionGeometry.resolve(
            anchor: CGPoint(x: -40, y: -20),
            end: CGPoint(x: 120, y: 160),
            maximumExcursion: 250,
            bounds: bounds
        ) == CGRect(x: 0, y: 0, width: 120, height: 160), "Dragged bounds clamp to local display coordinates")

        check(CaptureSelectionGeometry.resolve(
            anchor: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 140, y: 130),
            maximumExcursion: 0,
            bounds: CGRect(x: 200, y: 100, width: 700, height: 500)
        ) == CGRect(x: 0, y: 0, width: 700, height: 500), "Full-display bounds are local and positive")

        check(CaptureSelectionGeometry.resolve(
            anchor: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 10, y: 10),
            maximumExcursion: 15,
            bounds: .zero
        ) == nil, "Invalid display bounds do not produce a selection")

        print("Capture selection geometry checks passed")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
}
