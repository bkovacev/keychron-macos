// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "K10ProBattery",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "K10ProBattery",
            path: "Sources/K10ProBattery"
        )
    ]
)
