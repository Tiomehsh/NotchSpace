// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchSpace",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "NotchSpace", targets: ["NotchSpace"])
    ],
    targets: [
        .executableTarget(
            name: "NotchSpace",
            path: "Sources/NotchSpace"
        )
    ]
)
