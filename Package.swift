// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SGPosture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SGPosture",
            path: "Sources/SGPosture"
        )
    ]
)
