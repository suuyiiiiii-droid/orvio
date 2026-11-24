// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orvio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "T1Core", targets: ["T1Core"]),
        .library(name: "T1Platform", targets: ["T1Platform"]),
        .executable(name: "Orvio", targets: ["T1Controller"]),
        .executable(name: "T1DailyPreparation", targets: ["T1DailyPreparation"])
    ],
    targets: [
        .target(name: "T1Core"),
        .target(name: "T1Platform"),
        .executableTarget(name: "T1Controller", dependencies: ["T1Core", "T1Platform"]),
        .executableTarget(name: "T1DailyPreparation", dependencies: ["T1Core", "T1Platform"]),
        .testTarget(name: "T1CoreTests", dependencies: ["T1Core"]),
        .testTarget(name: "T1PlatformTests", dependencies: ["T1Platform"])
    ],
    swiftLanguageModes: [.v5]
)
