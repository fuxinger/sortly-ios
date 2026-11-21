// swift-tools-version: 6.0
// Albumist – platform-independent core.
// The iOS app (App/) links these libraries. Everything in here builds and tests on
// macOS, iOS and Linux so the business logic is verifiable without a Mac.
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "AlbumistKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "AlbumistCore", targets: ["AlbumistCore"]),
        .library(name: "AlbumistStore", targets: ["AlbumistStore"]),
        .library(name: "AlbumistWorldMap", targets: ["AlbumistWorldMap"]),
        .library(name: "AlbumistEngine", targets: ["AlbumistEngine"]),
        .library(name: "AlbumistTestSupport", targets: ["AlbumistTestSupport"]),
    ],
    targets: [
        // Apple platforms ship SQLite as the `SQLite3` module; Linux needs a module map.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "AlbumistCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "AlbumistStore",
            dependencies: [
                "AlbumistCore",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "AlbumistWorldMap",
            dependencies: ["AlbumistCore"],
            resources: [.copy("Resources/world.albumistmap"), .copy("Resources/LICENSE-NaturalEarth.txt")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "AlbumistEngine",
            dependencies: ["AlbumistCore", "AlbumistStore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "AlbumistTestSupport",
            dependencies: ["AlbumistCore"],
            swiftSettings: strictSettings
        ),
        // Files of the UI tests built here as well so Linux tests them: test12's pause check,
        // which app process the end of the app is about (UITestLaunchRecord), and the app's lifecycle
        // lines next to a Home press (UITestLifecycle).
        .target(
            name: "AlbumistUITestLogic",
            path: "App/AlbumistUITests",
            sources: ["PauseCountCheck.swift", "UITestLaunchRecord.swift", "UITestLifecycle.swift"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AlbumistUITestLogicTests",
            dependencies: ["AlbumistUITestLogic"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AlbumistCoreTests",
            dependencies: ["AlbumistCore", "AlbumistWorldMap", "AlbumistTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AlbumistStoreTests",
            dependencies: ["AlbumistStore", "AlbumistCore", "AlbumistTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AlbumistEngineTests",
            dependencies: ["AlbumistEngine", "AlbumistStore", "AlbumistCore", "AlbumistWorldMap", "AlbumistTestSupport"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
