// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacResourceMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacResourceMonitor",
            path: "MacResourceMonitor",
            exclude: ["Info.plist", "MacResourceMonitor.entitlements"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
