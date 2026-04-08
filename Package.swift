// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacResourceMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacResourceMonitor",
            path: "src",
            exclude: ["Info.plist", "MacResourceMonitor.entitlements"],
            resources: [
                .copy("Resources/AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
