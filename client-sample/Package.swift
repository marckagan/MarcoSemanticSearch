// swift-tools-version:5.9
// Illustrative package wrapper -- exists so the parts of the client sample
// that don't depend on a real Core ML model (QueryEngine.rank's
// cosine-ranking, QueryEmbedder's prefix correctness, SearchIndexStore's
// SQLite round-trip) can be built and tested with `swift test`. Not a
// template for the real iOS app's project structure -- a real app links
// this logic into an Xcode project targeting iOS, not a SwiftPM package
// targeting macOS the way this test wrapper does.

import PackageDescription

let package = Package(
    name: "ClientSample",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClientSample"),
        .testTarget(name: "ClientSampleTests", dependencies: ["ClientSample"]),
    ]
)
