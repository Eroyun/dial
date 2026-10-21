import CoreGraphics
import Foundation

@main
enum CaptureScrollGeometryTests {
    static func main() {
        let viewport = CGRect(x: 100, y: 0, width: 800, height: 600)
        precondition(CaptureScrollGeometry.fraction(
            documentFrame: CGRect(x: 100, y: 0, width: 800, height: 1_200), viewportFrame: viewport) == 0)
        precondition(CaptureScrollGeometry.fraction(
            documentFrame: CGRect(x: 100, y: -300, width: 800, height: 1_200), viewportFrame: viewport) == 0.5)
        precondition(CaptureScrollGeometry.fraction(
            documentFrame: CGRect(x: 100, y: -600, width: 800, height: 1_200), viewportFrame: viewport) == 1)

        let translatedViewport = CGRect(x: 1_100, y: 1_000, width: 800, height: 600)
        let translatedDocument = CGRect(x: 1_100, y: 700, width: 800, height: 1_200)
        precondition(CaptureScrollGeometry.fraction(documentFrame: translatedDocument,
                                                     viewportFrame: translatedViewport) == 0.5,
                     "Common screen-coordinate translation does not change progress")

        precondition(CaptureScrollGeometry.fraction(
            documentFrame: CGRect(x: 0, y: -300, width: 700, height: 1_200), viewportFrame: viewport) == nil,
                     "A document narrower than the viewport is not a valid scroll position")
        precondition(CaptureScrollGeometry.fraction(
            documentFrame: CGRect(x: 100, y: 10, width: 800, height: 1_200), viewportFrame: viewport) == nil,
                     "A viewport outside the document is rejected")
        precondition(CaptureScrollGeometry.fraction(
            documentFrame: CGRect(x: 100, y: -300, width: 800, height: 600), viewportFrame: viewport) == nil,
                     "A fixed-height region is not treated as a scrolling document")
        precondition(CaptureScrollGeometry.fraction(
            documentFrame: CGRect(x: 100, y: -900, width: 800, height: 1_200), viewportFrame: viewport) == nil,
                     "Overscroll is unknown rather than clamped to an endpoint")
        precondition(CaptureScrollGeometry.fraction(
            documentFrame: CGRect(x: CGFloat.infinity, y: 0, width: 800, height: 1_200), viewportFrame: viewport) == nil)

        print("Capture scroll geometry fractions and invalid-boundary checks passed")
    }
}
