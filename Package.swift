// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Notchling",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Notchling", targets: ["Notchling"])
    ],
    targets: [
        .executableTarget(
            name: "Notchling",
            path: "Sources/Notchling",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
