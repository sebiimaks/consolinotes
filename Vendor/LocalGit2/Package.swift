// swift-tools-version:5.7
import PackageDescription

// Built locally from the pinned source shipped with the app. Never downloads a binary.
let package = Package(
    name: "LocalGit2",
    platforms: [.macOS(.v12)],
    products: [.library(name: "Cgit2", targets: ["Cgit2"])],
    targets: [
        .target(name: "Cgit2", dependencies: ["libgit2"],
                linkerSettings: [.linkedLibrary("iconv"), .linkedLibrary("z")]),
        .binaryTarget(name: "libgit2", path: "libgit2.xcframework")
    ]
)
