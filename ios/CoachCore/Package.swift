// swift-tools-version:5.9
// CoachCore: the 5K Coach logic (plan, cues, audio render, GPS filter, saved state),
// ported from the web app's js/*.js. Foundation only, so it builds and tests anywhere.
import PackageDescription

let package = Package(
    name: "CoachCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "CoachCore", targets: ["CoachCore"]),
    ],
    targets: [
        .target(name: "CoachCore"),
        .testTarget(
            name: "CoachCoreTests",
            dependencies: ["CoachCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
