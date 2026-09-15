// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CinemaHUD",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SonyCameraKit", targets: ["SonyCameraKit"]),
        .library(name: "CinemaUI", targets: ["CinemaUI"]),
        .executable(name: "CinemaHUD", targets: ["CinemaHUD"]),
        .executable(name: "usbprobe", targets: ["usbprobe"]),
    ],
    targets: [
        .target(name: "SonyCameraKit"),
        .target(name: "CinemaUI", dependencies: ["SonyCameraKit"]),
        .executableTarget(name: "CinemaHUD", dependencies: ["SonyCameraKit", "CinemaUI"]),
        .executableTarget(name: "usbprobe", dependencies: ["SonyCameraKit"]),
        .testTarget(name: "SonyCameraKitTests", dependencies: ["SonyCameraKit"]),
    ]
)
