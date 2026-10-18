// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SimpleMacFixes",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "SimpleMacFixes", targets: ["SimpleMacFixes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jaywcjlove/PermissionFlow.git", revision: "2f2a4b76b1eb2ff7ab815b977be8229853f10bf8"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // Finder cut, mouse scrolling and acceleration, shared event tap and app policy.
        .target(
            name: "SimpleMacFixesCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Ported from Macsimize.
        .target(
            name: "MaximizeFeature",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices")]
        ),
        // Ported from Dockmint: App Exposé only.
        .target(
            name: "DockExposeFeature",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices")]
        ),
        // Ported from Simple Mac Keyboard Control.
        .target(
            name: "KeyboardControlFeature",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "SimpleMacFixes",
            dependencies: [
                "SimpleMacFixesCore", "MaximizeFeature", "DockExposeFeature", "KeyboardControlFeature",
                .product(name: "PermissionFlow", package: "PermissionFlow"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "SimpleMacFixesCoreTests", dependencies: ["SimpleMacFixesCore"]),
        .testTarget(name: "KeyboardControlFeatureTests", dependencies: ["KeyboardControlFeature"]),
        .testTarget(name: "DockExposeFeatureTests", dependencies: ["DockExposeFeature"]),
        .testTarget(name: "MaximizeFeatureTests", dependencies: ["MaximizeFeature"]),
    ],
    swiftLanguageVersions: [.v5]
)
