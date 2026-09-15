// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CinemaHUD",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SonyCameraKit", targets: ["SonyCameraKit"]),
        .executable(name: "CinemaHUD", targets: ["CinemaHUD"]),
        .executable(name: "usbprobe", targets: ["usbprobe"]),
    ],
    targets: [
        .target(name: "SonyCameraKit"),
        .executableTarget(name: "CinemaHUD", dependencies: ["SonyCameraKit"]),
        .executableTarget(name: "usbprobe", dependencies: ["SonyCameraKit"]),
        .testTarget(name: "SonyCameraKitTests", dependencies: ["SonyCameraKit"]),
    ]
)
