// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TodayCore",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "TodayCore", targets: ["TodayCore"]),
    ],
    targets: [
        .target(name: "TodayCore"),
        .testTarget(name: "TodayCoreTests", dependencies: ["TodayCore"]),
    ]
)
