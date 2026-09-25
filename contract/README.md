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
| `pipeline_e2e.json` | 從錄音檔到紀錄的整條管線（用替身聽打引擎與替身 AI） |

## 重新產生（macOS 核心改了之後）

```bash
HEARBY_WRITE_CONTRACT=1 swift test --filter ContractFixtureTests   # 寫 contract/fixtures/*.json
dotnet test windows/tests/Hearby.Core.Tests                        # C# 要照樣全綠；不綠＝兩邊行為分岔了，改 C# 那邊
```

不設 `HEARBY_WRITE_CONTRACT` 時，Swift 的測試是拿現有的 fixtures 比對，確認 macOS 核心沒有不小心改變輸出。
這一版的 fixtures 來自 macOS 核心 2.1.0（build 22）；產生它們的 Swift 測試（`Tests/HearbyCoreTests/ContractFixtureTests.swift`）會跟 macOS 2.1.0 的原始碼一起公開，在那之前上面的重新產生指令還跑不了，C# 那邊照常用現有的 fixtures 測。
