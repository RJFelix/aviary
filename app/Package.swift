// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aviary",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Aviary", targets: ["Aviary"]),
        .executable(name: "AviarySelfTest", targets: ["AviarySelfTest"]),
        .library(name: "AviaryCore", targets: ["AviaryCore"]),
    ],
    targets: [
        .target(
            name: "AviaryCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Aviary",
            dependencies: ["AviaryCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Not a `.testTarget`: this machine's toolchain is Command Line Tools only,
        // which ships neither XCTest nor swift-testing. Running the suite as an
        // executable keeps it usable everywhere. See Sources/AviarySelfTest/Harness.swift.
        .executableTarget(
            name: "AviarySelfTest",
            dependencies: ["AviaryCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
