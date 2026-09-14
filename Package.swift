// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PlsInput",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlsInputCore", targets: ["PlsInputCore"]),
        .executable(name: "plsbot", targets: ["plsbot"]),
    ],
    targets: [
        .target(
            name: "PlsInputCore",
            path: "Sources/PlsInputCore"
        ),
        .executableTarget(
            name: "plsbot",
            dependencies: ["PlsInputCore"],
            path: "Sources/plsbot"
        ),
        .testTarget(
            name: "PlsInputCoreTests",
            dependencies: ["PlsInputCore"],
            path: "Tests/PlsInputCoreTests"
        ),
    ]
)
