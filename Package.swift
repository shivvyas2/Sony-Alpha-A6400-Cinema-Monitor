// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CinemaHUD",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SonyCameraKit", targets: ["SonyCameraKit"]),
        .library(name: "CinemaAudio", targets: ["CinemaAudio"]),
        .library(name: "CinemaUI", targets: ["CinemaUI"]),
        .executable(name: "CinemaHUD", targets: ["CinemaHUD"]),
        .executable(name: "usbprobe", targets: ["usbprobe"]),
    ],
    targets: [
        .target(name: "SonyCameraKit"),
        .target(name: "CinemaAudio"),
        .target(name: "CinemaUI", dependencies: ["SonyCameraKit", "CinemaAudio"]),
        .executableTarget(
            name: "CinemaHUD",
            dependencies: ["SonyCameraKit", "CinemaUI", "CinemaAudio"],
            linkerSettings: [
                // Embed Info.plist in the bare executable so `swift run` builds can use the microphone
                // (macOS terminates a process that touches the mic without NSMicrophoneUsageDescription).
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"])
            ]
        ),
        .executableTarget(name: "usbprobe", dependencies: ["SonyCameraKit"]),
        .testTarget(name: "SonyCameraKitTests", dependencies: ["SonyCameraKit", "CinemaUI"]),
        .testTarget(name: "CinemaAudioTests", dependencies: ["CinemaAudio"]),
    ]
)
