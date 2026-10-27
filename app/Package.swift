// swift-tools-version:5.9
// Lets `swift build` and Xcode (File > Open this folder) compile the app's sources. The app itself is still built by
// ./build.sh (bundle, art, signing) and checked by ./test.sh: the checks compile these same files with -D TESTING,
// which one SwiftPM target cannot do a second time. A binary from `swift build` has no bundle id, so it reads none of the
// app's settings; run the app from build.sh. Keep `sources` in step with the swiftc line in build.sh.
import PackageDescription

let package = Package(
    name: "Soulgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Soulgent", targets: ["Soulgent"])],
    targets: [
        .executableTarget(
            name: "Soulgent",
            path: ".",
            // Art, tables and tools are copied in by build.sh; build/, tmp/ and Soulgent.app are what build.sh and test.sh leave.
            exclude: ["brand", "i18n", "themes", "tools", "pets", "build", "tmp", "Soulgent.app"],
            sources: [
                "Panel.swift",
                "Data/Session.swift",
                "Data/Dump.swift",
                "Data/Loader.swift",
                "Adapters/ClaudeCode.swift",
                "Adapters/Codex.swift",
                "Adapters/WorkBuddy.swift",
                "Adapters/Orca.swift",
                "Office.swift",
                "Extensions.swift",
                "ZoneModel.swift",
                "ZoneView.swift",
                "ZoneFX.swift",
                "SessionSearch.swift",
                "JumpMark.swift",
                "Settings.swift",
                "L10n.swift",
                "DemoCrowd.swift",
                "NoExtensions.swift",
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
