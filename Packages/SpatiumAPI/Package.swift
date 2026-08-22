// swift-tools-version: 6.0
import PackageDescription

/// The generated SpatiumDDI REST client.
///
/// Kept as a local package rather than wired into the app target directly: the
/// generator runs as a build tool plugin, and a package manifest expresses that
/// far more legibly than an Xcode project file. It also means the client can be
/// built and inspected on its own, without the app.
let package = Package(
    name: "SpatiumAPI",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "SpatiumAPI", targets: ["SpatiumAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.1"),
    ],
    targets: [
        .target(
            name: "SpatiumAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(
            name: "SpatiumAPITests",
            dependencies: ["SpatiumAPI"]
        ),
    ]
)
