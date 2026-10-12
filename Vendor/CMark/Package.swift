// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "libcmark_gfm",
    products: [.library(name: "libcmark_gfm", targets: ["libcmark_gfm"])],
    targets: [.target(name: "libcmark_gfm", path: "Sources", publicHeadersPath: "include",
                      cSettings: [.define("CMARK_GFM_STATIC_DEFINE"), .define("CMARK_GFM_EXTENSIONS_STATIC_DEFINE")])]
)
