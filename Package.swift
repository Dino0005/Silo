// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Silo",
    platforms: [.macOS(.v15)],
    targets: [
        // Thin executable: defers entirely to SiloKit (so all logic stays testable).
        .executableTarget(
            name: "silo",
            dependencies: ["SiloKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // All app logic + views live here so the test target can import them.
        .target(
            name: "SiloKit",
            dependencies: ["CShaderFix"],
            resources: [.process("Resources")],   // steam.png (toolbar "Open Steam" icon)
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // macprotips' SpiderMan2Fix shader rewrite (public domain, C): typed pool access → raw, on the
        // `dxc -dumpbin` text of the game's own shaders (`SpiderMan2Fix.ShaderBuilder`).
        .target(name: "CShaderFix"),
        .testTarget(
            name: "SiloKitTests",
            dependencies: ["SiloKit"],
            resources: [.copy("Fixtures")],   // sample .acf/.vdf + fake prefix trees
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
