// swift-tools-version: 6.0
// ArisReader macOS native shell (SwiftPM, see docs/adr/0006).
//
// Layout:
//   ArisReaderKit     — UI library (reusable by smoke scenarios / future test targets)
//   ArisReader  — executable app (@main)
//
// Rust binding integration lands in M0 T0.9: scripts/build-rust.sh generates
//   Sources/aris_reader_ffiFFI/{aris_reader_ffiFFI.h, module.modulemap}
//   Sources/ArisReaderFFI/Generated/*.swift
// and the binary target plus linker settings are added at the commented-out
// spot below (see docs/05-ffi.md §8).

import PackageDescription

let package = Package(
    name: "ArisReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ArisReader", targets: ["ArisReader"]),
        .library(name: "ArisReaderKit", targets: ["ArisReaderKit"]),
    ],
    targets: [
        .target(
            name: "ArisReaderKit",
            path: "Sources/ArisReaderKit"
        ),
        .executableTarget(
            name: "ArisReader",
            dependencies: ["ArisReaderKit"],
            path: "Sources/ArisReader"
        ),

        // ── M0 T0.9: Rust static library and UniFFI-generated bindings (not yet enabled) ──────────────
        // .target(
        //     name: "aris_reader_ffiFFI",
        //     path: "Sources/aris_reader_ffiFFI",
        //     publicHeadersPath: ".",
        //     linkerSettings: [
        //         .unsafeFlags(["-L", ".rust/lib"]),
        //         .linkedLibrary("aris_reader_ffi"),
        //         .linkedFramework("Metal"),
        //         .linkedFramework("QuartzCore"),
        //     ]
        // ),
        // .target(name: "ArisReaderFFI", dependencies: ["aris_reader_ffiFFI"], path: "Sources/ArisReaderFFI"),
    ]
)
