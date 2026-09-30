// EntryFiles — ~/Hearby/CLAUDE.md 與 AGENTS.md（給 AI 讀的入口；資料夾即專案）
import Foundation

public enum EntryFiles {
    public static let claudeMD = """
        # 這是我的會議記憶（Hearby 整理的）

        - 認識的人、在談的事、還沒完成的事：`memory/` 裡五個檔，先讀 `THREADS.md` 和 `OPEN.md`
        - 要找哪一場：`memory/index.json`；逐字稿與紀錄在 `會議/<日期_時間_標題>/`
        - 每份紀錄的結構：`## AI 會議摘要`／`## 與會者`／`## 重點`／`## 決議`／`## 待辦`／`## 逐字稿`；重點與決議每行尾的 [mm:ss] 是逐字稿裡的出處
        - 我跟你討論完的新決定，請直接寫進 `memory/THREADS.md` 對應那條，待辦寫進 `memory/OPEN.md`（格式：`- [ ] 事項｜負責人｜期限｜會議id`）
        - 你幫我改了紀錄裡的人名：改之前先留 `<檔名>.bak-日期`，改完跑 Hearby 的 `--memory-rebuild <那份 md>`（指令寫在 AGENTS.md），改過的名字會記進 `memory/NAMES.md`，下一場自己就對
        - 要改一場的標題：用 Hearby（紀錄清單滑到那一場按筆，或跑 `--rename <那份 md> "<新標題>"`），不要自己改 `會議/` 裡的資料夾名或檔名（記憶的路徑會斷）
        - 規矩：我手改過的行不要動；不確定的標 [[?]]；不要發明我沒說過的話；不要動 `會議/` 裡的 .m4a
        """

    /// 缺就建（不覆蓋使用者改過的）
    public static func ensure() {
        let fm = FileManager.default
        for name in ["CLAUDE.md", "AGENTS.md"] {
            let u = Paths.root.appendingPathComponent(name)
            if !fm.fileExists(atPath: u.path) {
                let text = (Html.templateURL("\(name).tmpl").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? claudeMD
                try? text.write(to: u, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 「跟 Claude 討論」的第一句話（桌面版 Claude 新 session 帶進去；也複製到剪貼簿）
    public static func continueQuestion(mdURL: URL) -> String {
        let rel = mdURL.path.replacingOccurrences(of: Paths.root.path + "/", with: "")
        let title = mdURL.deletingPathExtension().lastPathComponent
        return "我們剛開完〈\(title)〉，紀錄在 \(rel)，讀完先列三個我該接著決定的事"
    }
    /// 沒有桌面版 Claude 時的退路：開終端機在 ~/Hearby/ 跑 claude。
    /// 標題來自檔名（匯入的音檔叫什麼就是什麼），是外來字串：一律包單引號，shell 不會展開裡面的 $( )、反引號與變數。
    public static func continueCommand(mdURL: URL, claude: String = "claude") -> String {
        "cd \(shellQuote(Paths.root.path)) && \(shellQuote(claude)) \(shellQuote(continueQuestion(mdURL: mdURL)))"
    }

    /// POSIX 單引號跳脫：整串包單引號，字串裡的單引號寫成 '\''
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
