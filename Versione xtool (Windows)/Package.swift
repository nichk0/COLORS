// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Colorista",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        // Un progetto xtool contiene una sola libreria: l'app.
        .library(
            name: "Colorista",
            targets: ["Colorista"]
        ),
    ],
    targets: [
        .target(
            name: "Colorista"
        ),
    ],
    swiftLanguageModes: [.v5]
)
