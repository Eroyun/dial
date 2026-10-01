// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dial",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CDDC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "Dial",
            dependencies: ["CDDC"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
