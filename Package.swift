// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KickbaseMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KickbaseMac",
            path: "Sources/KickbaseMac"
        )
    ]
)
