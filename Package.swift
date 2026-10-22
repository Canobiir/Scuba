// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Scuba",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Scuba",
            path: "Sources/Scuba",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
