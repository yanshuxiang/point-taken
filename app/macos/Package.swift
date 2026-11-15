// swift-tools-version:5.9
// Point Taken (macOS). `swift build -c release --product point-taken`; build-app.sh assembles the .app bundle around
// the `point-taken` executable and installs it.
import Foundation
import PackageDescription

// POINT_TAKEN_SDK_VERSION=27.2 (build-app.sh sets it from the installed SDK): Swift Build records the deployment
// target (13.0) as the SDK the app was built with, so macOS runs it in compatibility mode with the old look — no
// Liquid Glass. Telling the linker the real SDK version keeps 13.0 as the oldest supported system and lets the
// current system draw the app in its own style.
let sdkVersion = ProcessInfo.processInfo.environment["POINT_TAKEN_SDK_VERSION"].flatMap { $0.isEmpty ? nil : $0 }
let appLinkerFlags = sdkVersion.map { ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "13.0", "-Xlinker", $0] } ?? []

let package = Package(
    name: "PointTaken",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "point-taken", targets: ["PointTakenApp"]),
        .library(name: "PointTakenCore", targets: ["PointTakenCore"]),
    ],
    targets: [
        // Config, paths, the script runner (uv + login-shell environment), hotkeys, the annotation archive and its
        // exports. No AppKit UI here — everything public is what PointTakenApp (and tests) may use.
        .target(name: "PointTakenCore", path: "Sources/PointTakenCore"),
        // PointTakenTry: catches the Objective-C exceptions AVFoundation raises (Swift can't), so a mic format change
        // never aborts the app.
        .target(name: "PointTakenObjC", path: "Sources/PointTakenObjC"),
        // The app: Capture/ (the annotation session: capsule, ink, review, history), App/ (delegate, menu, hotkeys,
        // model downloads), Settings/, Onboarding/ (permissions), Icons/, System/. main.swift = launch.
        .executableTarget(
            name: "PointTakenApp",
            dependencies: ["PointTakenCore", "PointTakenObjC"],
            path: "Sources/PointTakenApp",
            // string tables: build-app.sh copies Resources/*.lproj into Contents/Resources (Loc finds them there, or
            // next to the sources for a plain `swift build` run) — not SwiftPM resources.
            exclude: ["Resources"],
            linkerSettings: appLinkerFlags.isEmpty ? [] : [.unsafeFlags(appLinkerFlags)]),
        .testTarget(name: "PointTakenCoreTests", dependencies: ["PointTakenCore", "PointTakenObjC"], path: "Tests/PointTakenCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
