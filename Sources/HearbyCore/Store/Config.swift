// Config — config.json（schemaVersion 1）：原子寫入、執行緒安全快取
//
// 資料契約（開源後別人要接的東西）：欄位只加不改；改語意就升 schemaVersion 並寫遷移。
// 落點＝Paths.support/config.json。讀不到或壞掉＝用預設值，不擋啟動；壞檔留 .broken-<時間> 不覆蓋。

import Foundation

public struct Config: Codable, Equatable {
    public static let currentSchema = 1

    public var schemaVersion: Int = Config.currentSchema
    /// 使用者資料根；nil＝~/Hearby
    public var outputRoot: String? = nil
    /// 第二落點（副本）；nil＝不寫
    public var mirrorDir: String? = nil
    /// 整理用哪個：none（只要逐字稿）／claude／codex／endpoint（本機模型：Ollama、LM Studio 或自己的伺服器）
    public var provider: String = "none"
    /// 外觀：system／light／dark
    public var appearance: String = "system"
    /// 常用詞檔；nil＝跟姊妹 app 共用那份（SharedPaths）
    public var glossaryPath: String? = nil
    /// 記憶回流（預設關；精靈收尾卡可開）
    public var memoryEnabled: Bool = false
    /// 整理時認聲音（實驗，只有 macOS 15 以上；預設關，見 Voices）
    public var voicesEnabled: Bool = false
    /// 精靈走完了沒；沒走完從第幾頁續
    public var wizardDone: Bool = false
    public var wizardStep: Int = 0
    /// 情境：meeting／interview／note
    public var scene: String = "meeting"
    /// 線上會議（開系統聲）
    public var online: Bool = false
    /// 匯出文件表頭預設（PDF／Word）：公司名、記錄人
    public var docCompany: String? = nil
    public var docRecorder: String? = nil
    /// 使用者自己選過整理方式（true＝自動挑不再覆蓋）
    public var providerChosen: Bool? = nil
    public var claudePath: String? = nil
    public var claudeModel: String? = nil
    public var claudeEffort: String? = nil
    public var codexPath: String? = nil
    public var codexModel: String? = nil
    /// 聽打模型鏡像（選填，base URL）
    public var modelMirror: String? = nil
    /// 每場自動出 PDF（預設關：按需一鍵）
    public var autoPDF: Bool = false
    /// 上次的會前準備（開錄前那一行）
    public var lastBrief: String? = nil
    /// 錄音中面板收起來時，螢幕上放一條小狀態列；nil＝開（預設）
    public var floatingBar: Bool? = nil
    /// 本機模型端點（provider＝endpoint）：位址（nil＝http://127.0.0.1:11434，Ollama 預設）與模型名
    public var endpointURL: String? = nil
    public var endpointModel: String? = nil

    public init() {}

    public var floatingBarOn: Bool { floatingBar ?? true }

    /// 加欄位不破壞舊檔：每個欄位缺了就用預設值
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        outputRoot = try c.decodeIfPresent(String.self, forKey: .outputRoot)
        mirrorDir = try c.decodeIfPresent(String.self, forKey: .mirrorDir)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        glossaryPath = try c.decodeIfPresent(String.self, forKey: .glossaryPath)
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? d.memoryEnabled
        voicesEnabled = try c.decodeIfPresent(Bool.self, forKey: .voicesEnabled) ?? d.voicesEnabled
        wizardDone = try c.decodeIfPresent(Bool.self, forKey: .wizardDone) ?? d.wizardDone
        wizardStep = try c.decodeIfPresent(Int.self, forKey: .wizardStep) ?? d.wizardStep
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? d.scene
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? d.online
        docCompany = try c.decodeIfPresent(String.self, forKey: .docCompany)
        docRecorder = try c.decodeIfPresent(String.self, forKey: .docRecorder)
        providerChosen = try c.decodeIfPresent(Bool.self, forKey: .providerChosen)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel)
        claudeEffort = try c.decodeIfPresent(String.self, forKey: .claudeEffort)
        codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath)
        codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel)
        modelMirror = try c.decodeIfPresent(String.self, forKey: .modelMirror)
        autoPDF = try c.decodeIfPresent(Bool.self, forKey: .autoPDF) ?? d.autoPDF
        lastBrief = try c.decodeIfPresent(String.self, forKey: .lastBrief)
        floatingBar = try c.decodeIfPresent(Bool.self, forKey: .floatingBar)
        endpointURL = try c.decodeIfPresent(String.self, forKey: .endpointURL)
        endpointModel = try c.decodeIfPresent(String.self, forKey: .endpointModel)
    }
}

public final class ConfigStore {
    public static let shared = ConfigStore()

    private let lock = NSLock()
    private var cache: Config?

    public var url: URL { Paths.support.appendingPathComponent("config.json") }

    /// 目前設定（第一次讀檔，之後走快取）
    public var current: Config {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let c = load()
        cache = c
        return c
    }

    /// 改一部分並存檔（原子）
    public func update(_ mutate: (inout Config) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var c = cache ?? load()
        mutate(&c)
        try write(c)
        cache = c
    }

    /// 丟掉快取（測試換沙箱用）
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        cache = nil
    }

    private func load() -> Config {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return Config() }
        do {
            let d = try Data(contentsOf: url)
            var c = try JSONDecoder().decode(Config.self, from: d)
            if c.schemaVersion < Config.currentSchema {
                // 之後有 schema 2 在這裡遷移；現在只把版號抬上來
                c.schemaVersion = Config.currentSchema
            }
            return c
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? fm.copyItem(at: url, to: url.appendingPathExtension("broken-\(stamp)"))
            HearbyLog.write("config.json 讀不到，用預設值：\(error)")
            return Config()
        }
    }

    private func write(_ c: Config) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(c)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".config.json.tmp-\(getpid())")
        try data.write(to: tmp, options: .atomic)
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    }
}
