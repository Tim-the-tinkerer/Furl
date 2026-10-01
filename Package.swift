// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Furl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Furl", targets: ["Furl"]),
        .library(name: "FurlCore", targets: ["FurlCore"]),
        .executable(name: "FurlTests", targets: ["FurlTests"]),
    ],
    targets: [
        .target(
            name: "CFurl",
            path: "Sources/CFurl",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-O3"]),
            ]
        ),
        .target(
            name: "FurlCore",
            dependencies: ["CFurl"],
            path: "Sources/FurlCore"
        ),
        .executableTarget(
            name: "Furl",
            dependencies: ["FurlCore"],
            path: "Sources/Furl"
        ),
        .executableTarget(
            name: "FurlTests",
            dependencies: ["FurlCore"],
            path: "Tests/FurlTests"
        ),
    ]
)
