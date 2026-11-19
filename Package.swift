// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kickoff",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kickoff", targets: ["Kickoff"]),
    ],
    targets: [
        .executableTarget(
            name: "Kickoff",
            path: "Sources/Kickoff",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "KickoffTests",
            dependencies: ["Kickoff"],
            path: "Tests/KickoffTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
