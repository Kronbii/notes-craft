// swift-tools-version: 6.2

import Foundation
import PackageDescription

// `NOTESCRAFT_CORE_ONLY=1 swift test` builds and tests the platform-independent
// core on any host (including Linux) without the UIKit app target.
let coreOnly = ProcessInfo.processInfo.environment["NOTESCRAFT_CORE_ONLY"] != nil

var products: [Product] = []
var targets: [Target] = [
    .target(
        name: "NotesCraftCore",
        path: "Sources/NotesCraftCore"
    ),
    .testTarget(
        name: "NotesCraftCoreTests",
        dependencies: ["NotesCraftCore"],
        path: "Tests/NotesCraftCoreTests"
    ),
]

if coreOnly {
    products.append(.library(name: "NotesCraftCore", targets: ["NotesCraftCore"]))
} else {
    // An xtool project contains exactly one library product: the app.
    products.append(.library(name: "NotesCraft", targets: ["NotesCraft"]))
    targets.append(
        .target(
            name: "NotesCraft",
            dependencies: ["NotesCraftCore"],
            path: "Sources/NotesCraft",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                // The on-device test harness (tours, stress test) exists only in
                // debug builds; release builds never contain it.
                .define("NOTESCRAFT_DEV", .when(configuration: .debug)),
            ]
        )
    )
}

let package = Package(
    name: "NotesCraft",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: products,
    targets: targets
)
