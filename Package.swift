// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DawnTranslate",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DawnTranslate", targets: ["DawnTranslate"])],
    targets: [
        .executableTarget(name: "DawnTranslate")
    ]
)
