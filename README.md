# Hearby

開會按一下，結束就有一份紀錄。紀錄存在你自己的電腦裡、是純文字，你用哪個 AI 都能接著討論；
開的會越多，它越懂你在做什麼。中文英文夾著講也聽得準，錄音留著隨時點回去聽，不用月費。

macOS 與 Windows 都有。<!-- windows -->

## 它做什麼

- **錄音**：麥克風與電腦裡的聲音分兩軌錄（同一個房間開會只要麥克風，不需要系統聲音權限）；錄音檔以崩潰安全的方式寫入，整理中電腦睡著會暫停、醒來接著做並說明原因。
  麥克風只開輸入裝置、不碰聲音輸出，開關都有等待上限：Mac 的音訊服務卡住時，按開始 3 秒內說明原因、按停止最多等 2 秒，app 不會跟著卡住；錄音中換麥克風會自動跟過去，麥克風中途斷掉會自己接回來。
  中途可以**暫停／繼續**（暫停的那段不存，整場仍是一份紀錄，逐字稿標出暫停的位置）；面板收起來時螢幕上有一條小狀態列（在錄還是暫停、幾分幾秒、麥克風有沒有聲音），選單列圖示旁也顯示計時；麥克風兩分鐘收不到聲音會提醒。
- **聽打**：whisper.cpp（Metal）在本機跑，長錄音自動切片；幻聽句濾網；小聲的片段先放大再聽打並在紀錄上註明；也能匯入既有的音檔或影片（⌘O）。
- **整理**：用你自己已登入的 Claude Code 或 Codex（不用 API 金鑰）；或交給你自己裝的本機模型（Ollama、LM Studio，或自己的伺服器；建議 16 GB 以上記憶體，整理得比較簡略）；或只要逐字稿。三種情境各有版型：會議紀錄／訪談稿／筆記。
- **紀錄**：一場一個資料夾，`.md`＋`.m4a`（另可出 `.docx`、PDF、`.srt`）；可以自己改、請 AI 改一段、重新整理全篇、翻譯（英／日／簡中）。
- **記憶**：`~/Hearby/memory/` 五個純文字檔與 `index.json`，讓你的 AI 知道認識的人、在談的事、還沒完成的事。紀錄改過（重新整理全篇、自己改、請 AI 改一段）記憶跟著換；你在記憶裡改過、打勾、刪掉的行不動，改到既有的行之前先留 `<檔名>.bak-日期`。
- **名冊**（選用）：在 `memory/` 放一份 `ROSTER.md`（誰是誰、常被聽錯成什麼），整理時人名與案子照名冊寫，逐字稿裡聽錯的名字只改那一行、沒把握的標 `[[?]]`；沒記過的新錯法（唸起來像名冊上的名字）也會挑出來給 AI 看上下文判斷；已定案的事不再列成開放問題。
- **認聲音**（實驗，macOS 15 以上，預設關）：整理前分出誰在講話；記住過的人（要本人同意）標出名字，摘要與與會者就寫對人。聲紋只存在這台 Mac、可以隨時忘記。格式見 `AGENTS.md`。
- **越開會越記得**（記憶開著）：你改過一次的名字記進 `memory/NAMES.md`，下一場自己就對；AI 沒把握的名字在紀錄頁問你一次，答了就不再問；紀錄多一節「之前的事」寫上次的待辦與案子這場怎麼了，做完的自動打勾。
- **安裝**：DMG 裡拖進「應用程式」或直接雙擊都能裝；四頁設定精靈；`--doctor --deep` 體檢。

還沒做：自動更新（macOS 版；Windows 版有）、會前準備自動帶入。

## 下載

[**下載 Hearby.dmg**](https://github.com/intentionltd888/hearby/releases/latest/download/Hearby.dmg)（Apple Silicon 的 Mac，macOS 14 以上；已通過 Apple 公證）。打開 DMG，把 Hearby 拖進「應用程式」，或直接雙擊它。

**Windows**：到 [Releases](https://github.com/intentionltd888/hearby/releases) 找標題有「Windows」的版本，下載 `Hearby-Setup.exe`（目前 1.0.0：[直接下載](https://github.com/intentionltd888/hearby/releases/download/win-v1.0.0/Hearby-Setup.exe)；Windows 10 22H2／Windows 11，x64）。安裝檔沒有數位簽章：Windows 會跳「Windows 已保護您的電腦」→ 按「其他資訊」→「仍要執行」。不需要系統管理員權限，會自動更新。Windows 版的說明與跟 macOS 版的差別見 [windows/README.md](windows/README.md)。

所有版本在 [Releases](https://github.com/intentionltd888/hearby/releases)。哪些東西會離開你的電腦，寫在 [PRIVACY.md](PRIVACY.md)。

## 自己建置需要什麼

- Apple Silicon 的 Mac，macOS 14 以上
- Xcode 命令列工具（`xcode-select --install`）
- 聽打引擎（whisper.cpp）用 `scripts/vendor-fetch.sh` 準備；不進 git

## 建置

```bash
swift build            # 開發
swift test             # 測試（永遠在沙箱裡，不碰 ~/Hearby）
bash scripts/vendor-fetch.sh   # 聽打引擎進 vendor/（本機有現成的就複製，否則從源碼編）
bash build.sh                  # 組 build/Hearby.app（含引擎）
bash scripts/make-dmg.sh       # 未公證的 DMG（自己裝用；留在 build/，不進 2_版本）
bash scripts/notarize.sh       # 給人的：Apple 公證＋釘票（app 與 DMG 兩段）
bash scripts/ship.sh           # 出貨閘：清洗檢查＋驗票都過才放進出貨夾
build/Hearby.app/Contents/MacOS/Hearby --doctor --deep
```

終端機也能用（沙箱：設 `HEARBY_OUTPUT_ROOT`／`HEARBY_SUPPORT_DIR` 就不碰真資料夾）：

```bash
Hearby --import 會議.m4a --title 週會 --provider claude   # 聽打並整理一個音檔／影片（--provider 也可以是 endpoint＝設定裡的本機模型）
Hearby --record 40 --source online --pause-at 14 --resume-at 24 --no-process   # 開發用：真錄 40 秒、中途暫停 10 秒
Hearby --process <錄音工作夾> --provider none             # 對既有 mic.wav／system.wav 跑整理
Hearby --repolish <紀錄.md> "「Kevien」應為「Kevin」"        # 重新整理全篇
Hearby --memory-rebuild <紀錄.md>                          # 在別的編輯器改過紀錄：記憶跟著換（不給檔＝每一場）
Hearby --rename <紀錄.md 或那一場的資料夾> "新標題"          # 改標題：資料夾、檔名、紀錄表頭、meta、記憶裡的 id、副本一起換
Hearby --export-word <紀錄.md> --company 公司 --recorder 記錄人   # .docx，Pages 直接開
Hearby --translate <紀錄.md> --lang en                            # 另存 .en.md
Hearby --snapshot /tmp/shots                                      # 每個畫面畫成 PNG（設計檢視）
```

## 倉的長相

```
Sources/HearbyCore   引擎（錄音、辨識、清理、整理、匯出、記憶、設定）——零 AppKit，CLI 與測試直接叫
Sources/HearbyUI     設計系統（軟浮雕材質）＋畫面；Resources/Brand 是商標
Sources/HearbyApp    殼：選單列圖示、小面板、一個視窗、精靈、CLI 旗標
Tests/               幻聽回歸、清理、匯出、記憶寫入紀律
templates/           Word 三公版、pdf.html、CLAUDE.md／AGENTS.md 範本
windows/             Windows 版（C#／WPF）：Hearby.Core（核心的 C# 版）、Hearby.App（殼）、合約測試、build.sh——見 windows/README.md
contract/            macOS 核心在固定輸入下的輸出：Windows 核心照著逐字比對（contract/README.md）
scripts/             check-clean／check-binary（公開前清洗）、vendor-fetch／build、make-dmg、notarize、ship（出貨閘）
```

使用者資料全在 `~/Hearby/`（家目錄，不會彈任何權限視窗）。那個資料夾本身就是一個可以被 AI 讀的專案：
裡面有 `CLAUDE.md` 與 `AGENTS.md`，在裡面打開 Claude Code 或 Codex，記憶就在。

## 授權

程式碼 MIT（見 `LICENSE`）。`Sources/HearbyUI/Resources/Brand/` 裡的標記、字標與圖示是商標，不在 MIT 範圍（見該夾 `TRADEMARK.md`）。
第三方元件見 `THIRD-PARTY.md`（Windows 版見 `windows/THIRD-PARTY-WINDOWS.md`）；隱私見 `PRIVACY.md`；接第三方 AI 的規矩見 `COMPLIANCE.md`。
