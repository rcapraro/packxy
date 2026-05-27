// swift-tools-version:5.9
//
// Packxy macOS app — Swift Package Manager manifest.
//
// We use SPM rather than an .xcodeproj because the toolchain here ships
// Command Line Tools only (no `xcodebuild`), and a hand-maintained
// project.pbxproj is a UUID-laden mess that doesn't survive git review.
// SPM gives us a clean executable target; the Makefile wraps the output
// into a proper .app bundle (Info.plist + icon + ad-hoc codesign) using
// the same sips/iconutil pipeline the Go bundle already uses.
//
// Single-target executable: the Swift menu-bar app lives in
// Sources/Packxy. No external dependencies — UserNotifications,
// SwiftUI, AppKit and ServiceManagement (SMAppService) are part of the
// SDK.

import PackageDescription

let package = Package(
    name: "Packxy",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Packxy",
            path: "Sources/Packxy"
        ),
    ]
)
