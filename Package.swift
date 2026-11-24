// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AcerDisplayControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AcerDisplayControl", targets: ["AcerDisplayControl"]),
        .executable(name: "acerctl", targets: ["acerctl"])
    ],
    targets: [
        .target(
            name: "CDDC",
            path: "Sources/CDDC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreDisplay"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "DisplayCore",
            dependencies: ["CDDC"],
            path: "Sources/DisplayCore"
        ),
        .executableTarget(
            name: "AcerDisplayControl",
            dependencies: ["DisplayCore", "CDDC"],
            path: "Sources/AcerDisplayControl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "acerctl",
            dependencies: ["DisplayCore"],
            path: "Sources/acerctl"
        ),
        .testTarget(
            name: "DisplayCoreTests",
            dependencies: ["DisplayCore", "AcerDisplayControl"],
            path: "Tests/DisplayCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
