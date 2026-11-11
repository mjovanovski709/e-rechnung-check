// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ERechnungCheck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EInvoiceKit", targets: ["EInvoiceKit"]),
        .executable(name: "erechnung-check", targets: ["erechnung-check"]),
        .executable(name: "ERechnungCheck", targets: ["ERechnungCheckApp"]),
    ],
    targets: [
        // Everything that reads and checks an invoice. No UI, no network.
        .target(name: "EInvoiceKit"),
        // Command-line front end, also used to sweep sample collections.
        .executableTarget(name: "erechnung-check", dependencies: ["EInvoiceKit"]),
        // The Mac app. Scripts/build-app.sh wraps this binary into a .app bundle.
        .executableTarget(name: "ERechnungCheckApp", dependencies: ["EInvoiceKit"]),
        .testTarget(
            name: "EInvoiceKitTests",
            dependencies: ["EInvoiceKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
