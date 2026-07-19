// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacResourceMonitor",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.6.0")),
    ],
    targets: [
        .executableTarget(
            name: "MacResourceMonitor",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "src",
            exclude: ["Info.plist", "MacResourceMonitor.entitlements"],
            resources: [
                .copy("Resources/AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedLibrary("IOReport"),  // private dyld-cache lib for power/freq sampling (Apple Silicon)
            ]
        ),
        .testTarget(
            name: "MacResourceMonitorTests",
            dependencies: ["MacResourceMonitor"],
            path: "Tests/MacResourceMonitorTests"
        ),
    ]
)
