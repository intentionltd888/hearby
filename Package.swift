// swift-tools-version:5.9
// hearby-mac — 三個 target：
//   HearbyCore  引擎（錄音、辨識、清理、整理、匯出、記憶、設定），零 AppKit，CLI 與測試直接叫
//   HearbyUI    設計系統（軟浮雕材質）＋畫面，不含業務邏輯
//   HearbyApp   殼：選單列圖示、小面板、一個視窗、精靈、CLI 旗標分派
import PackageDescription

let package = Package(
    name: "hearby-mac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HearbyCore", targets: ["HearbyCore"]),
        .library(name: "HearbyUI", targets: ["HearbyUI"]),
        .executable(name: "Hearby", targets: ["HearbyApp"]),
    ],
    targets: [
        .target(name: "HearbyCore", path: "Sources/HearbyCore"),
        .target(
            name: "HearbyUI", dependencies: ["HearbyCore"], path: "Sources/HearbyUI",
            resources: [.copy("Resources/Brand")]),
        .executableTarget(
            name: "HearbyApp", dependencies: ["HearbyCore", "HearbyUI"], path: "Sources/HearbyApp"),
        .testTarget(name: "HearbyCoreTests", dependencies: ["HearbyCore"], path: "Tests/HearbyCoreTests"),
    ]
)
