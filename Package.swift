// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CCVerify",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CCVerify", path: "Sources/CCVerify")
    ]
)
