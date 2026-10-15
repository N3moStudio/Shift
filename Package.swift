// swift-tools-version: 5.9
import PackageDescription

// Foundation-only reliability rules can be tested without an iPhone, iOS SDK,
// pairing secrets, or the device-only idevice static library.
let package = Package(
    name: "LocusReliability",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SessionPresentation", path: "Shared", exclude: ["LocusActivityAttributes.swift", "ShiftBrandViews.swift"]),
        .testTarget(name: "SessionPresentationTests", dependencies: ["SessionPresentation"], path: "Tests")
    ]
)
