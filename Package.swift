// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GarethMacVirtualCameraTests",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CameraTimeline", targets: ["CameraTimeline"]),
    ],
    targets: [
        .target(
            name: "CameraTimeline",
            path: "Extension",
            exclude: [
                "Extension.entitlements",
                "ExtensionProvider.swift",
                "Info.plist",
                "main.swift",
                "video.mp4",
            ],
            sources: ["SampleTimestampValidator.swift"]
        ),
        .testTarget(
            name: "CameraTimelineTests",
            dependencies: ["CameraTimeline"]
        ),
    ]
)
