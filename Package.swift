// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kickoff",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Kickoff", targets: ["Kickoff"]),
    ],
    targets: [
        .target(
            name: "CAXNavigation",
            path: "Sources/CAXNavigation",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        .executableTarget(
            name: "Kickoff",
            dependencies: ["CAXNavigation"],
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
