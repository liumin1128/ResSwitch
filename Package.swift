// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ResSwitch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ResSwitch", targets: ["ResSwitch"])
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayBridge",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "ResSwitch",
            dependencies: ["CGVirtualDisplayBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
