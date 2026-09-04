// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "coroner",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "coroner", targets: ["coroner"]),
        .library(name: "CoronerCore", targets: ["CoronerCore"]),
    ],
    targets: [
        .target(name: "CoronerCore"),
        .executableTarget(
            name: "coroner",
            dependencies: ["CoronerCore"],
            path: "Sources/coroner"
        ),
        .testTarget(
            name: "coronerTests",
            dependencies: ["CoronerCore", "coroner"],
            path: "Tests/coronerTests",
            exclude: ["Fixtures"]
        ),
    ]
)
