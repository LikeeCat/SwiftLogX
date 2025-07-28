// swift-tools-version: 6.0

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SwiftLogX",
    platforms: [.macOS(.v13), .iOS(.v14)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftLogX",
            targets: ["SwiftLogX"]
        ),
        .library(
            name: "SwiftLogXMacros",
                 targets: ["SwiftLogXMacros"]),

    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0-latest"),
        .package(url: "https://github.com/httpswift/swifter.git", .upToNextMajor(from: "1.5.0"))
    ],
    targets: [
        .target(name: "SwiftLogX",
        dependencies: [
            .product(name: "Swifter", package: "swifter")
        ],
        path: "Sources/SwiftLogX",
        resources: [.process("Resources")]
       ),

        .macro(
            name: "SwiftLogXMacroDeclarations",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Sources/SwiftLogXMacroDeclarations"
        ),

        .target(
            name: "SwiftLogXMacros",
            dependencies: ["SwiftLogXMacroDeclarations","SwiftLogX"],
            path: "Sources/SwiftLogXMacros"
        ),
        // A test target used to develop the macro implementation.
        .testTarget(
            name: "SwiftLogXTests",
            dependencies: [
                "SwiftLogXMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
