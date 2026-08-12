// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Archive",
    platforms: [.macOS(.v13), .iOS(.v15), .tvOS(.v15), .watchOS(.v10)],
    products: [
        .library(name: "Archive", targets: ["Archive"]),
    ],
    targets: [
        .target(
            name: "CArchive",
            path: "libarchive",
            publicHeadersPath: ".",
            cSettings: [
                .define("PLATFORM_CONFIG_H", to: "\"config_spm.h\""),
            ],
            linkerSettings: [
                .linkedLibrary(
                    "iconv",
                    .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])
                ),
                .linkedLibrary("crypto", .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "Archive",
            dependencies: ["CArchive"],
            path: "Sources/Archive"
        ),
    ]
)
