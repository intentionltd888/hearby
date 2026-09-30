# TESTING-WINDOWS.md — Windows 版驗收條目

狀態：✅＝已驗；◐＝程式面已驗、實機待驗；—＝還沒驗。

1.0.0 的驗證環境：macOS 上的 QEMU 虛擬機，Windows 11 25H2 繁體中文 ARM64 版（x64 程式以相容模式執行，沒有實體顯示卡、麥克風是無聲的虛擬音效卡），使用者帳號名是中文（路徑含中文字）。
**還沒在實體的 x64 Windows 筆電上跑過**：速度、真的麥克風收音、顯示卡加速、SmartScreen 實際畫面，都等實機驗（見最後一節）。

| # | 條 | 狀態 |
|---|---|---|
| 1 | 核心與 macOS 版輸出一致：15 組合約測試（切片、幻聽、清理、整理的提示與守門、紀錄格式、記憶、暫停、端到端管線） | ✅ `dotnet test`：15/15 |
| 2 | 在 macOS 上建出安裝檔（不需要 Windows）；安裝檔 10 秒內裝好、不需要管理員；開始功能表與桌面各一個捷徑；裝完直接開精靈 | ✅ 虛擬機實裝 |
| 3 | 使用者名稱是中文（`C:\Users\測試者`）：資料夾、模型、錄音、聽打、紀錄都正常 | ✅ |
| 4 | 聽打引擎需要的微軟 C++ 執行階段隨附（全新 Windows 沒有也能跑）；四個 DLL 是微軟簽章原檔 | ✅ 全新系統上沒隨附時聽打全失敗、隨附後正常；`Get-AuthenticodeSignature` Valid |
| 5 | 聽打模型下載：斷點續傳、核對 SHA-256；精靈第一頁按下去就在背景下載、進度看得到 | ✅ 574 MB 約 40 秒、校驗通過 |
| 6 | 「線上會議」：麥克風＋電腦裡的聲音兩軌錄；沒有任何 app 出聲時電腦裡那軌照樣連續（靜音保活） | ✅ 35 秒錄音收到 3,519 段系統聲、逐字稿正確；麥克風軌無聲時紀錄上有說明 |
| 7 | 暫停／繼續：暫停的那段不存，逐字稿標出暫停位置，切片在暫停處切開 | ✅ 介面與命令列都驗過 |
| 8 | 面板收起來時浮動條出現、計時會走、暫停與停止按得到；面板打開就收掉 | ✅ 介面測試（截圖） |
| 9 | 聽打在子行程跑；顯示卡是軟體模擬的（虛擬機、遠端桌面）就改用處理器；用的是哪一種寫進紀錄檔 | ✅ 虛擬機走處理器 |
| 10 | 匯入音檔與影片：m4a、mp3、wav、flac、wma、aiff（Mac 產生的 AIFC：twos／sowt／fl32，24-bit 立體聲）、mp4、mkv；沒有聲音軌的影片說清楚；拖到面板上也能匯入 | ✅ 11 種檔逐一轉檔、時長與音量正確；Mac 的 AIFC 從匯入到紀錄整條跑通；拖放待實機 |
| 11 | 整理：只要逐字稿；本機模型（Ollama，qwen3:4b-instruct）整理出摘要、與會者、重點、決議、待辦；重新整理全篇先備份 | ✅ |
| 12 | Claude Code：官方指令安裝（不用管理員）、未登入時說清楚、「登入」開瀏覽器並提供貼代碼的欄位、取消 | ✅ 到瀏覽器打開登入頁為止（真的登入要有人的帳號，見最後一節） |
| 13 | 匯出 Word（.docx）與 PDF（Edge 背景排版，頁面不准跑程式碼、不准載入外部資源） | ✅ 兩種都產出、版型與 macOS 同一套 |
| 14 | 紀錄視窗：清單、搜尋、單場頁（紀錄／逐字稿）、只有逐字稿的紀錄直接開逐字稿；設定頁、檢查頁 | ✅ 截圖檢查（淺色、深色） |
| 15 | 精靈四頁：麥克風被隱私權設定關掉時有路走（打開 Windows 設定、可下一步） | ◐ 程式面；關掉麥克風的實機待驗 |
| 16 | 小螢幕（800×600）：精靈與匯出視窗等比縮小、面板與紀錄視窗縮到螢幕內 | ✅ |
| 17 | 自動更新：偵測新版 → 背景下載 → 「現在更新」套用並自動重開 | ✅ 本機資料夾當更新來源，1.0.0 → 1.0.1 |
| 18 | 解除安裝：程式與捷徑移除；紀錄、設定、模型留著 | ✅ |
| 19 | 已經開著時再開一次 Hearby：不會開第二個，改成把面板／紀錄視窗叫到前面 | ◐ 程式面 |
| 20 | 錄音中或整理中從工作列選單結束：先問 | ◐ 程式面 |
| 21 | 清洗檢查（`scripts/check-clean.sh --strict`）綠；二進位不含這台機器的路徑 | ✅ |
| 22 | 記憶跟著紀錄走（重新整理全篇、自己改、請 AI 改一段、`--memory-rebuild [<md>]`）與別名表（不收 `#` 標題行與 HTML 註解）：跟 macOS 同一套 | ✅ 合約測試 `memory_sync`、`alias_table` |
| 23 | 名冊與名字更正（`memory\ROSTER.md` 在才帶；AI 的名字更正只改那幾行、沒把握標 `[[?]]`；名冊上的名字不被簡轉繁改掉）：跟 macOS 同一套 | ✅ 合約測試 `build_notes`（`meeting_roster*`）、`name_fixes`、`record_md`；`RosterNamesSurviveConversion` |
| 24 | 名字確認帳（NAMES.md：自己改、重新整理的更正、--memory-rebuild 都記下改過的名字；撞名檢查；要確認在紀錄頁答一次）：跟 macOS 同一套 | ✅ 合約測試 `name_ledger` |
| 25 | 現況（STATE.md：待辦與定案用它的、另外帶案子現況與還沒定的事）：跟 macOS 同一套 | ✅ 合約測試 `name_ledger`（makeWithState）、`build_notes` |
| 26 | 之前的事（紀錄一節、做完的把別場待辦打勾）：跟 macOS 同一套 | ✅ 合約測試 `name_ledger`（follow*）、`build_notes` |
| 27 | 讀音比對（候選一節、簡稱守門、拼音表同一份）：跟 macOS 同一套 | ✅ 合約測試 `sound_alike`、`name_fixes`、`build_notes` |
| 28 | 改標題（清單滑過出現筆、右鍵「改標題…」、原地改；`--rename <md 或資料夾> "<新標題>"`）：跟 macOS 同一套 | ✅ 合約測試 `meeting_rename`；介面 ◐ 程式面 |

## 怎麼驗（虛擬機）

- 介面測試不用點滑鼠：`HEARBY_UI_SCRIPT="show online 2 start 4 screenshot hide 3 screenshot pause 4 resume 20 stop 150 screenshot quit"` 照順序對面板下指令，`screenshot` 把每個開著的視窗存成 PNG 到 `%LOCALAPPDATA%\Hearby\Logs\`。其他指令：`records`／`settings`／`status`／`wizard`、`wstep0`…`wstep4`、`export`、`lastrecord`、`dark`／`light`、`claudelogin`／`claudecancel`、`updatecheck`／`updateapply`、`quit`。
- 錄音要在使用者登入的桌面工作階段裡跑（SSH 的工作階段沒有音訊）：用「工作排程器」的互動式工作啟動。
- 更新：用 `vpk pack --packVersion 1.0.1` 打一包放到資料夾，`HEARBY_UPDATE_FEED=<資料夾>` 啟動已安裝的 Hearby，下 `updatecheck` 再 `updateapply`。

## 還要在實體 Windows 電腦上驗的

1. 一台一般的 x64 筆電（例如 Intel i5／i7、內建顯示晶片）：一小時會議的聽打時間、顯示卡加速有沒有用上（`hearby.log` 的 `whisper backend:` 那行）。
2. 真的麥克風：同一個房間開會、戴耳機的線上會議、開喇叭的線上會議（迴聲去重）、錄音中插拔耳機。
3. 從瀏覽器真的下載安裝檔：SmartScreen 的畫面與「仍要執行」。
4. 用自己的 Claude 帳號登入一次、整理一場。
5. Windows 10 22H2。
