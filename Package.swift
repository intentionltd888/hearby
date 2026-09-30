// swift-tools-version:6.2
// hearby-mac — 四個 target：
//   HearbyCore  引擎（錄音、辨識、清理、整理、匯出、記憶、設定），零 AppKit、零第三方套件，CLI 與測試直接叫
//   HearbyVoice 認聲音（說話人分段＋聲紋比對，FluidAudio／Core ML）；只有這裡拉第三方套件，HearbyCore 透過 Voices.engine 叫它
//   HearbyUI    設計系統（軟浮雕材質）＋畫面，不含業務邏輯
//   HearbyApp   殼：選單列圖示、小面板、一個視窗、精靈、CLI 旗標分派
// tools 6.2：為了關掉 FluidAudio 用不到的文字正規化引擎（traits: []，少帶一個 87 MB 的二進位框架）；語言模式維持 Swift 5
import PackageDescription

let package = Package(
    name: "hearby-mac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HearbyCore", targets: ["HearbyCore"]),
        .library(name: "HearbyUI", targets: ["HearbyUI"]),
        .executable(name: "Hearby", targets: ["HearbyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4", traits: []),
    ],
    targets: [
        .target(name: "HearbyCore", path: "Sources/HearbyCore"),
        .target(
            name: "HearbyVoice", dependencies: ["HearbyCore", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/HearbyVoice"),
        .target(
            name: "HearbyUI", dependencies: ["HearbyCore"], path: "Sources/HearbyUI",
            resources: [.copy("Resources/Brand")]),
        .executableTarget(
            name: "HearbyApp", dependencies: ["HearbyCore", "HearbyUI", "HearbyVoice"], path: "Sources/HearbyApp"),
        .testTarget(name: "HearbyCoreTests", dependencies: ["HearbyCore"], path: "Tests/HearbyCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
