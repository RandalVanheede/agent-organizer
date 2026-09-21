// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentOrganizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentOrganizer", targets: ["AgentOrganizer"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentOrganizer",
            dependencies: ["SwiftTerm"],
            path: "Sources/AgentOrganizer"
        )
    ]
)
