// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RokidSpatial",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RokidSpatial", targets: ["RokidSpatial"]),
        .executable(name: "rokid-orient", targets: ["RokidOrient"]),
        .executable(name: "rokid-probe", targets: ["RokidProbe"]),
        .library(name: "RokidKit", targets: ["RokidKit"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(
            name: "RokidKit",
            dependencies: ["CLibUSB"],
            path: "Sources/RokidKit"
        ),
        .target(
            name: "CGVirtualDisplayShim",
            path: "Sources/CGVirtualDisplayShim",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "RokidSpatial",
            dependencies: ["RokidKit", "CGVirtualDisplayShim"],
            path: "Sources/RokidSpatial"
        ),
        .executableTarget(
            name: "RokidOrient",
            dependencies: ["RokidKit"],
            path: "Sources/RokidOrient"
        ),
        .executableTarget(
            name: "RokidProbe",
            path: "Sources/RokidProbe"
        ),
    ]
)
