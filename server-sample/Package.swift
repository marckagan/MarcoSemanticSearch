// swift-tools-version:5.9
// Illustrative package wrapper -- exists so the parts of ChunkAndEmbed.swift
// that don't depend on a real MLX model (Chunker's windowing logic,
// Embedder's prefix correctness) can be built and tested with `swift test`.
// Not a template for the real farm service's project structure.

import PackageDescription

let package = Package(
    name: "ServerSample",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ServerSample"),
        .testTarget(name: "ServerSampleTests", dependencies: ["ServerSample"]),
    ]
)
