import Foundation

@main enum EndpointNavigationTests {
    static func check(_ condition: Bool, _ message: String = "Check failed",
                      file: StaticString = #file, line: UInt = #line) {
        precondition(condition, message, file: file, line: line)
    }

    static func main() {
        check(EndpointNavigation.seekWheelPixels(towardTop: true) == 1_000_000)
        check(EndpointNavigation.seekWheelPixels(towardTop: false) == -1_000_000)
        check(EndpointNavigation.boundedWheelPixels(1_000_000, endpointSeek: true) == 1_000_000)
        check(EndpointNavigation.boundedWheelPixels(-1_500_000, endpointSeek: true) == -1_000_000)
        check(EndpointNavigation.boundedWheelPixels(1_000_000, endpointSeek: false) == 180,
              "Endpoint seeking must not raise ordinary wheel limits")
        check(EndpointNavigation.boundedWheelPixels(-3_000, endpointSeek: false) == -180)
        check(EndpointNavigation.ordinaryWheelLimit(viewportHeight: 948) == 180)
        check(EndpointNavigation.ordinaryWheelLimit(viewportHeight: 240) == 48)
        check(EndpointNavigation.ordinaryWheelLimit(viewportHeight: 100) == 20)
        check(EndpointNavigation.ordinaryWheelLimit(viewportHeight: .infinity) == 0)
        print("Endpoint navigation: directed seek bounds and ordinary wheel limits passed")
    }
}
