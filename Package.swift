// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentOrganizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentOrganizer", targets: ["AgentOrganizer"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentOrganizer",
            dependencies: ["SwiftTerm", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AgentOrganizer"
        )
    ]
)
