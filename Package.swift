// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kikitori",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Kikitori", path: "Sources/Kikitori")
    ]
)
