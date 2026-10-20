// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeedSentry",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SpeedSentryCore", targets: ["SpeedSentryCore"]),
        .executable(name: "SpeedSentry", targets: ["SpeedSentry"])
    ],
    targets: [
        .target(name: "SpeedSentryCore"),
        .executableTarget(name: "SpeedSentry", dependencies: ["SpeedSentryCore"]),
        .testTarget(name: "SpeedSentryCoreTests", dependencies: ["SpeedSentryCore"])
    ]
)
