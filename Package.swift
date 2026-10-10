// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MailBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MailBar", path: "Sources/MailBar")
    ]
)
