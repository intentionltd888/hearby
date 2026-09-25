# Hearby for Windows

開會按一下，結束就有一份紀錄——Windows 版。錄音、聽打、整理都在你自己的電腦上做；紀錄是純文字，存在你自己的資料夾。
跟 macOS 版同一套核心規則（同一份合約測試），介面照同一套設計重做。

## 下載與安裝

1. 到 [Releases](https://github.com/intentionltd888/hearby/releases) 找標題有「Windows」的版本，下載 **`Hearby-Setup.exe`**（約 100 MB）。
2. 雙擊。安裝檔沒有數位簽章，Windows 會跳出「Windows 已保護您的電腦」：按 **「其他資訊」→「仍要執行」**。
3. 不用系統管理員權限，十秒左右裝好：開始功能表與桌面各一個 Hearby，裝完直接打開設定精靈。
4. 精靈第一頁按「開始設定」，聽打模型（約 0.6 GB）會在背景下載，一次就好。

- **需要**：Windows 10 22H2 或 Windows 11，x64 處理器（Intel／AMD）；建議 8 GB 以上記憶體。ARM 處理器（Snapdragon）的 Windows 11 以相容模式執行，能用但聽打比較慢。
- **SHA-256**：每個版本的 Release 頁附 `SHA256SUMS.txt`，PowerShell 可以 `Get-FileHash .\Hearby-Setup.exe` 自己比對。
- **「智慧型應用程式控制」（Smart App Control）**：這個功能開著的 Windows 11 會直接擋掉沒有簽章的程式、沒有「仍要執行」可按。大部分電腦沒有開；有開的話目前沒辦法安裝，只能等之後有簽章的版本。
- **更新**：Hearby 會在背景向 GitHub 查新版，有的話先下載好，下次打開就換新（設定 → 更新 可以關掉自動檢查，或按「現在更新」）。
- **解除安裝**：設定 › 應用程式 › 已安裝的應用程式 › Hearby › 解除安裝。你的紀錄（`%USERPROFILE%\Hearby`）與設定、模型（`%LOCALAPPDATA%\Hearby`）會留著；不要了可以自己刪。

## 怎麼用

- 工作列右下角（時間旁邊）那顆引號 **”** 就是 Hearby：按一下開面板，右鍵有選單。Windows 11 會把新圖示先收在 **^** 裡，拖到外面比較好找。
- 面板：會議／採訪／筆記三選一，「同一個房間」或「線上會議」，按中間的大圓開始、再按一次停止。可以中途暫停。
- 面板收起來時，螢幕上方有一條小狀態列（在錄還是暫停、幾分幾秒、麥克風有沒有聲音、暫停與停止）；它會請 Windows 不要把它放進螢幕分享與錄影畫面（Windows 10 2004 以後；實際效果依分享用的 app 而定）。
- 停止後自動聽打、整理，好了跳通知。紀錄視窗可以看、自己改、請 AI 改一段、重新整理全篇、翻譯、存成 PDF／Word、接著跟 Claude 討論。
- 已經有錄好的音檔或影片：面板上的「匯入音檔」，或直接把檔案拖到面板上。支援 m4a／mp3／wav／aac／wma／flac／aiff 與 mp4／mov／m4v／wmv／avi／mkv。

## 跟 macOS 版的差別

| | Windows 版 | macOS 版 |
|---|---|---|
| 住哪 | 工作列右下角的通知區 | 選單列 |
| 權限 | 不跳視窗；只看「設定 › 隱私權與安全性 › 麥克風」有沒有開。錄電腦裡的聲音不需要權限 | 麥克風、系統聲音各問一次 |
| 聽打引擎 | whisper.cpp（經 Whisper.net）：有 Vulkan 顯示卡就用顯示卡，沒有就用處理器；每一片在獨立的子行程裡跑，顯示卡驅動當掉也不會拖垮 app | whisper.cpp（Metal） |
| 聽打模型 | large-v3-turbo 量化版（q5_0，約 0.6 GB）；模型夾裡放完整版也會用 | large-v3-turbo（約 1.6 GB） |
| 整理方式 | 你自己的 Claude Code、本機模型（Ollama／LM Studio）、只要逐字稿 | 另外有 ChatGPT（Codex） |
| PDF | 用這台電腦的 Microsoft Edge 在背景排版（不開視窗；那一頁不准跑程式碼、不准載入任何外部資源） | WebKit |
| 更新 | 自動（GitHub Releases，可關） | 沒有自動更新 |

ChatGPT（Codex）在 Windows 版先不開放：macOS 版把 codex 整顆關在 Hearby 自己的外層沙箱裡跑，逐字稿裡夾帶的指令才碰不到你的檔案；Windows 上還沒有同等的做法，做到之前不開。

## 資料放在哪

| 位置 | 內容 |
|---|---|
| `%USERPROFILE%\Hearby\` | 紀錄：`會議\<日期_時間_標題>\`（`.md`、`.m4a`、匯出的 `.docx`／`.pdf`）、`memory\`、`CLAUDE.md`／`AGENTS.md` |
| `%LOCALAPPDATA%\Hearby\` | 設定 `config.json`、聽打模型 `models\`、錄音工作夾 `recordings\`（整理完 30 天後移到資源回收筒）、紀錄檔 `Logs\hearby.log` |
| `%LOCALAPPDATA%\HearbyApp\` | 程式本身（安裝程式放的；解除安裝會移除） |

哪些東西會離開你的電腦，寫在根目錄的 [PRIVACY.md](../PRIVACY.md)。

## 從原始碼建置

在 macOS 或 Linux 上就能建出 Windows 安裝檔（不需要 Windows、不需要 Visual Studio）：

```bash
# .NET SDK 10（https://dot.net），cabextract（brew install cabextract／apt install cabextract）
bash windows/build.sh
# → build/windows/release/Hearby-Setup.exe（＋更新用的 .nupkg、releases.win.json、SHA256SUMS.txt）
```

`build.sh` 依序做：合約測試 → 發佈（win-x64，自帶 .NET）→ 把微軟 C++ 執行階段（4 個 DLL，固定版本、逐檔核對 SHA-256）放在 Hearby.exe 旁邊 → 用 Velopack 打包安裝檔。安裝檔沒有簽章。

只跑測試：`dotnet test windows/tests/Hearby.Core.Tests`。

```
windows/
  src/Hearby.Core/        核心（C#）：聽打切片與幻聽濾網、清理、整理的提示與守門、紀錄格式、記憶、設定、匯出——沒有任何 Windows 專屬呼叫
  src/Hearby.App/         殼（WPF）：錄音（NAudio／WASAPI）、聽打子行程（Whisper.net）、工作列圖示、面板、浮動條、紀錄視窗、精靈、安裝與更新（Velopack）
  tests/Hearby.Core.Tests 合約測試：拿 ../contract/fixtures 的 macOS 輸出逐字比對
  build.sh                建置與打包
```

### 為什麼有 `contract/`

Windows 版的核心是 macOS 版（Swift）一行一行翻成 C# 的。為了確定兩邊做出來的紀錄一模一樣，macOS 的測試會把核心在固定輸入下的輸出寫成 `contract/fixtures/*.json`，C# 的測試拿同一份輸入跑、逐字比對。說明見 [contract/README.md](../contract/README.md)。

## 命令列

Hearby.exe 是視窗程式；在 PowerShell 裡接 `| Out-Host`，PowerShell 才會等它跑完、把輸出印出來。
沙箱：設 `HEARBY_OUTPUT_ROOT`／`HEARBY_SUPPORT_DIR`／`HEARBY_LOG_DIR` 就不碰真正的資料夾。

```powershell
$h = "$env:LOCALAPPDATA\HearbyApp\current\Hearby.exe"
& $h --doctor --deep | Out-Host                         # 七項體檢
& $h --download-model | Out-Host                        # 下載聽打模型
& $h --import 會議.m4a --title 週會 --provider claude | Out-Host   # 聽打並整理一個音檔（endpoint＝設定裡的本機模型）
& $h --record 40 --source online --pause-at 14 --resume-at 24 --no-process | Out-Host   # 開發用：真錄 40 秒、中途暫停 10 秒
& $h --process <錄音工作夾> --provider none | Out-Host
& $h --repolish <紀錄.md> "「Kevien」應為「Kevin」" | Out-Host
& $h --export-word <紀錄.md> --company 公司 --recorder 記錄人 | Out-Host
& $h --export-pdf <紀錄.md> | Out-Host
```

測試鉤（給自動化測試用，一般使用用不到）：`HEARBY_UI_SCRIPT="show online 2 start 20 stop"` 照順序對面板下指令；`HEARBY_AUTOIMPORT=<檔>` 走「匯入音檔」同一條路；`HEARBY_AUTOQUIT=1` 到完成或出錯就結束；`HEARBY_UPDATE_FEED=<資料夾>` 從本機資料夾測更新；`HEARBY_UI_NOFIT=1` 視窗照設計尺寸（在小螢幕上檢查版面）。驗收紀錄見 [TESTING-WINDOWS.md](TESTING-WINDOWS.md)。

## 授權

程式碼 MIT（根目錄 `LICENSE`）。第三方元件與授權見 [THIRD-PARTY-WINDOWS.md](THIRD-PARTY-WINDOWS.md)（其中微軟 C++ 執行階段依 Visual Studio 授權條款隨附，不是 MIT）。
`src/Hearby.App/Assets/` 的標誌、字標、圖示、照片與 `src/Hearby.App/UI/Brand.cs` 裡的標記幾何是商標與攝影資產，不在 MIT 範圍，條款同 `Sources/HearbyUI/Resources/Brand/TRADEMARK.md`。
