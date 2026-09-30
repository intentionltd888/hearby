# contract/ — macOS 核心與 Windows 核心的合約

Windows 版（`windows/src/Hearby.Core`，C#）是 macOS 版核心（`Sources/HearbyCore`，Swift）翻過去的。
同一段錄音、同一份逐字稿，兩邊要做出一模一樣的紀錄：切片位置、幻聽濾網、清理、交給 AI 的提示、AI 輸出的守門、紀錄的格式、記憶檔、暫停標記。

`fixtures/*.json` 是 macOS 核心在固定輸入下的輸出（輸入也寫在同一份檔裡）。C# 的測試（`windows/tests/Hearby.Core.Tests`）讀同一份輸入、逐字比對輸出。

| 檔 | 內容 |
|---|---|
| `slices.json`、`quiet_boost.json` | 長錄音在哪裡切、小聲片段怎麼放大 |
| `whisper_json.json`、`degeneracy.json`、`hallucination.json` | 讀聽打結果、重複迴圈、幻聽句 |
| `clean_punct.json`、`merged_for_llm.json`、`misc.json` | 標點與清理、交給 AI 前的合併、雜項（時間格式、資料夾名稱…） |
| `build_notes.json`、`polish_guards.json`、`repolish_parts.json` | 整理的提示與 AI 輸出的守門、重新整理 |
| `record_md.json`、`memory.json`、`pause.json` | 紀錄 md 的解析與客戶版、記憶檔、暫停標記 |
| `name_ledger.json` | 名字確認帳（NAMES.md）：讀寫、答題、帶進名冊的行、撞名檢查、從「A」應為「B」與改前改後學名字（含對齊與每一處怎麼切）、紀錄表頭的要確認 |
| `sound_alike.json` | 讀音比對：拼音表（SHA-256）、注音轉拼音、聽起來一樣／差一點、名冊 → 比對目標、逐字稿 → 候選與排序、帶給 AI 的行、簡稱守門 |
| `name_fixes.json` | 名冊（ROSTER.md → 帶給 AI 的名冊、已定案、待辦）與 AI 回的名字更正怎麼套（改哪幾行、哪些不改、標 [[?]]、表頭一行、重複的待辦） |
| `memory_sync.json`、`alias_table.json` | 紀錄改過之後記憶怎麼跟著換（哪幾行算 Hearby 的、使用者改過的不動、備份）；別名表（PEOPLE／GLOSSARY → 聽打後的替換） |
| `meeting_rename.json` | 改一場的標題：新夾名（保留日期時間、撞名加 -2）、夾裡哪些檔跟著改名、紀錄表頭、meta.json、記憶裡的 id 怎麼換（同一分鐘的另一場、更長的 id 不動）、副本資料夾、資料夾被人改過名時補齊、只差大小寫 |
| `pipeline_e2e.json` | 從錄音檔到紀錄的整條管線（用替身聽打引擎與替身 AI） |

## 重新產生（macOS 核心改了之後）

```bash
HEARBY_WRITE_CONTRACT=1 swift test --filter ContractFixtureTests   # 寫 contract/fixtures/*.json
dotnet test windows/tests/Hearby.Core.Tests                        # C# 要照樣全綠；不綠＝兩邊行為分岔了，改 C# 那邊
```

不設 `HEARBY_WRITE_CONTRACT` 時，Swift 的測試是拿現有的 fixtures 比對，確認 macOS 核心沒有不小心改變輸出。
產生 fixtures 用的 Swift 測試（`Tests/HearbyCoreTests/ContractFixtureTests.swift`）跟著 macOS 版的原始碼一起發佈；這一版的 fixtures 來自 macOS 核心 2.1.0（build 22）。
