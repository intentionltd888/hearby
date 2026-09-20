import Foundation

/// 幻聽濾網
///
/// **為什麼獨立成檔**：判定若跟 whisper 呼叫、切片、迴圈修補綁在一起，
/// 改一個門檻要重打整個 app 才知道有沒有誤殺。獨立之後零相依
///（只吃 Foundation），回歸測試可以單獨 `swiftc` 起來，拿 45,091 句真語料量前後差別。
/// 回歸集＝25 份保留的原始 whisper JSON（19,726 段）＋出貨逐字稿還原（25,365 句）。
///
/// ## 用聲音判斷幻聽：量過，切不開
///
/// 直覺上「用聲音判斷、不用文字判斷」可以一次解決整類問題。兩個聲音訊號都量過，都切不開：
///
/// - **`no_speech_prob` 沒有訊號**。patch 過的 whisper-cli 重跑三場共 3,520 段，
///   最大值 1.9e-5，沒有任何一段超過 0.6。而確定是幻聽的兩段「中文字幕志願者 李宗盛」
///  （各 30 秒）是 6.9e-8 與 1.3e-8——**全檔最低的一群**。模型一邊幻聽一邊確信這裡有人講話。
///   欄位本身留著（`Signals.noSpeechProb`）＋判定留著（`Rules.noSpeechCut`），但預設關，
///   換模型或換參數之後可以再量一次就開。
///
/// - **音訊 RMS 切不開**。一場樣本的幻聽段 RMS 0.01148，
///   真話「嗯」0.01187、「好」0.01193、「對」0.01295；全場最安靜的一段（0.00146、22 秒）
///   反而是真話。單麥房間錄音的底噪讓 16 秒室內音≈1 秒「嗯」。
///
/// - **whisper.cpp 內建的 Silero VAD（`--vad`）也量了，不開**（v5.1.2 與 v6.2.0 兩版模型）。
///   它擋純噪音很準（粉紅噪音 4 句幻聽→0 句；沒人講話的系統聲軌 7 句→1 句），但那幾句本來就在
///   下面的片語表裡、濾得掉。代價是會吃真話：一場平均 −41 dB 的真實會議，字數 5,990→5,395（v5）／
///   4,812（v6），被吃掉的 30 秒格回頭看是連貫的真對話；壓 −45 dB 的語音字錯率 9.8%→80.0%，
///   −55 dB 直接整段零字（不開 VAD 是 13.6%）。另外時間戳變粗（冒出 25 秒以上長段）。
///   這跟外界對 VAD 的實測一致：低電平會讓 VAD 把整段判成非語音。要開它得先全面拉平音量，
///   而那件事量過也不是乾淨的贏（見 `Transcriber.quietBoost` 註解）。
///
/// ## 實際有效的兩刀（回歸實測，零誤殺）
///
/// 1. **殘字門檻 4 → 6**，長段低字速再放寬到 10。＋5 −0。
///    樣本那句漏網就是差一個字：剝完剩「訂閱支持」4 字，判定式 `< 4`，`4 < 4` 為假 → 放行。
/// 2. **補三個漏網片語家族**（優優獨播劇場／YoYo Television Series Exclusive、
///    字幕:李宗盛、宣優獨播劇場）。＋16 −0。三種都已經洩進出貨逐字稿。
///
/// ⚠ 「強片語依長度由長到短排序」單獨下是**負分**：在門檻 4 之下它
/// ＋5 −43——救回樣本那句，卻放走 43 句「中文字幕志願者 李宗盛」（排序後「字幕志願者」
/// 先被吃掉，殘「中文李宗盛」5 字反而過關；舊的無序清單剛好先吃「中文字幕」，殘 3 字殺得掉）。
/// 門檻升到 6 之後排序才變成中性（回歸集上 F＝E，＋0 −0）。這裡**保留排序**是因為
/// 「靠清單打字順序決勝負」本身就是這個 bug 的來源，下一個加片語的人會再踩一次；
/// 但它只在門檻 ≥ 6 時安全，兩者是綁在一起的，不要單獨調其中一個。
public enum Hallucination {

    // MARK: - 片語表

    /// 強片語＝幻聽專屬句型（真人會議幾乎不可能講的字幕聲明／片尾詞）
    public static let strongJunkPatterns = [
        "謝謝觀看", "謝謝收看", "字幕由", "Amara", "amara.org", "字幕提供", "中文字幕",
        "MING PAO", "明鏡與點點", "♪", "🎵", "(音樂)", "[音樂]",
        // 8/19 實測補：靜音／低音量段會吐這幾種。注意判定是「逐條剝除後看殘字」，
        // 所以要把會一起出現的片語都列進來，剝完才剩不到門檻
        "字幕志願者", "志願者", "感謝觀看", "感謝收看", "請不吝", "點贊", "轉發", "打賞", "欄目", "點點欄目",
        // 實際會議錄音裡整批出現的 Whisper 靜音幻聽句型
        "已進行編輯", "以加入正確的標點符號", "以加入正確的標點", "編輯成功後",
        "以上言論不代表本台立場", "影片即將結束", "影片即將開始", "感謝您的觀看", "感謝您的收看",
        "這是一條語音備忘錄", "點點欄目", "轉發打賞", "打賞支持", "分享出去並按一個讚",
        // 掃保留的原始 whisper JSON 找出來的漏網家族（回歸實測 ＋16 −0）。
        // ① 出現過連續 11 段 × 30 秒都是這句＝5.5 分鐘被吃掉
        "優優獨播劇場", "宣優獨播劇場", "獨播劇場",
        "YoYo Television Series Exclusive", "Television Series Exclusive",
        // ② 逐字稿第一行就是「字幕：李宗盛」的那種。人名本身不能進黑名單（真的會議也可能聊到這個人），
        // 但「字幕:／詞:」開頭的掛名是幻聽專屬
        "字幕:李宗盛", "字幕：李宗盛", "詞:李宗盛", "詞：李宗盛",
    ]

    /// 弱片語＝真話裡也會出現的短詞，只在「佔整句一半以上」才判幻聽
    ///
    /// ⚠ 「訂閱」「支持」不移進強片語：移過去會誤殺
    /// 「要不要訂閱」這類短真話（剝掉「訂閱」剩 3 字 < 門檻），
    /// 而樣本那句光靠門檻 4→6 就殺得掉，不需要動這裡。
    public static let weakJunkPatterns = ["請訂閱", "訂閱", "點贊"]

    /// 整句幻聽白名單（靜音時 whisper 的固定產物，去頭尾標點後逐字命中即丟）
    public static let exactJunk: Set<String> = [
        "thank you.", "thank you", "thanks for watching.", "thanks for watching", "you",
        // 本機模型對 2 秒靜音 3/3 確定性轉出這句——整句精確比對零誤殺
        "中文字幕:cm 李宗盛", "中文字幕：cm 李宗盛",
    ]

    /// 強片語依長度由長到短排好。只在門檻 ≥ 6 時安全，理由見檔頭。
    public static let strongSorted = strongJunkPatterns.sorted { $0.count > $1.count }

    // MARK: - 引擎側證據

    /// 逐段的引擎側訊號。全部 optional：拿不到就退回純文字判定，不會比舊版差。
    /// 沒有這些欄位（例如匯入檔）照樣能用純文字入口。
    public struct Signals {
        /// whisper 自己算的「這段沒人在講話」機率（原版 whisper-cli 的 JSON 不吐這欄，拿到才用）。
        /// ⚠ 它是每 30 秒解碼窗一個值，
        /// 不是每段一個值；而且實測對本專案的幻聽沒有鑑別力，預設不使用。
        public var noSpeechProb: Double?
        /// 這一段涵蓋的音訊長度
        public var durationMs: Int?

        public init(noSpeechProb: Double? = nil, durationMs: Int? = nil) {
            self.noSpeechProb = noSpeechProb
            self.durationMs = durationMs
        }
    }

    /// 判定參數。產品用 `.shipping`；回歸測試換不同組來量前後差別。
    public struct Rules {
        /// 強片語剝除前依長度排序（見檔頭：與 `residueThreshold` 綁定，不要單獨調）
        public var sortStrongByLength = true
        /// 剝完剩幾個實字以下算幻聽
        public var residueThreshold = 6
        /// 長段低字速時放寬到這個門檻——幻聽的特徵是把一句罐頭話鋪滿整段靜音，真話不會。
        /// 回歸集 19,726 段裡符合「≥8 秒且 <1.5 字/秒」的只有 22 段。
        public var lowRateResidueThreshold = 10
        public var lowRateMinDurationMs = 8_000
        public var lowRateMaxCharsPerSec = 1.5
        /// `no_speech_prob` 超過就直接丟。nil ＝關掉（預設；實測無鑑別力，見檔頭）
        public var noSpeechCut: Double?

        public init(
            sortStrongByLength: Bool = true, residueThreshold: Int = 6,
            lowRateResidueThreshold: Int = 10, lowRateMinDurationMs: Int = 8_000,
            lowRateMaxCharsPerSec: Double = 1.5, noSpeechCut: Double? = nil
        ) {
            self.sortStrongByLength = sortStrongByLength
            self.residueThreshold = residueThreshold
            self.lowRateResidueThreshold = lowRateResidueThreshold
            self.lowRateMinDurationMs = lowRateMinDurationMs
            self.lowRateMaxCharsPerSec = lowRateMaxCharsPerSec
            self.noSpeechCut = noSpeechCut
        }

        /// 產品預設
        public static let shipping = Rules()
    }

    // MARK: - 判定

    /// 純文字入口（輸入法模式用：那邊一次只有幾秒近講話，沒有 whisper JSON 的逐段欄位）
    public static func isJunk(_ text: String) -> Bool {
        isJunk(text, signals: Signals(), rules: .shipping)
    }

    public static func isJunk(_ text: String, signals: Signals, rules: Rules = .shipping) -> Bool {
        if text.isEmpty { return true }  // 單字回應（好/對/是）屬有效發言，保留

        // 引擎說這段沒人講話 → 不看內容直接丟。預設關（實測無鑑別力），留著給換模型後重量。
        if let cut = rules.noSpeechCut, let p = signals.noSpeechProb, p > cut { return true }

        // 整句白名單
        let bare = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " 。．，,!！?？"))
        if exactJunk.contains(bare) { return true }

        // 一句話被攤在很長的時間上 → 放寬殘字門檻
        var threshold = rules.residueThreshold
        if let ms = signals.durationMs, ms >= rules.lowRateMinDurationMs,
            Double(text.count) / (Double(ms) / 1000) < rules.lowRateMaxCharsPerSec
        {
            threshold = max(threshold, rules.lowRateResidueThreshold)
        }

        // 強片語剝除 → 看殘字
        var stripped = text
        var strongHit = false
        for junk in (rules.sortStrongByLength ? strongSorted : strongJunkPatterns)
        where stripped.contains(junk) {
            strongHit = true
            stripped = stripped.replacingOccurrences(of: junk, with: "")
        }
        if strongHit, residue(stripped) < threshold { return true }

        // 弱片語走佔比制——殘字算法會誤殺「要不要訂閱」這類短真話
        return weakJunkPatterns.contains { junk in
            text.contains(junk) && junk.count * 2 >= text.count
        }
    }

    /// 殘字＝英數字＋CJK，標點與空白不算
    private static func residue(_ s: String) -> Int {
        s.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains(Int($0.value))
        }.count
    }
}
