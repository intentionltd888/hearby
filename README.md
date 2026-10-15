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
- **聽得懂台語**（國台混講；一般版預設關、**台語版**預設開；macOS 與 Windows 都有）：原本的模型沒把握或漏聽的地方，再交給台語模型（Breeze-ASR-26，約 1.1 GB，下載到這台電腦）聽一次，台語寫成華語用字；國語為主的會只多聽那幾段。
- **認聲音**（實驗，macOS 15 以上，預設關）：整理前分出誰在講話；記住過的人（要本人同意）標出名字，摘要與與會者就寫對人。聲紋只存在這台 Mac、可以隨時忘記。
- **越開會越記得**（記憶開著）：你改過一次的名字記進 `memory/NAMES.md`，下一場自己就對；AI 沒把握的名字在紀錄頁問你一次，答了就不再問；紀錄多一節「之前的事」寫上次的待辦與案子這場怎麼了，做完的自動打勾。
- **安裝**：DMG 裡拖進「應用程式」或直接雙擊都能裝；四頁設定精靈；`--doctor --deep` 體檢。

還沒做：自動更新（macOS 版；Windows 版有）、會前準備自動帶入。

## 下載

[**下載 Hearby.dmg**](https://github.com/intentionltd888/hearby/releases/latest/download/Hearby.dmg)　·　[**下載 Hearby 台語版.dmg**](https://github.com/intentionltd888/hearby/releases/download/taigi-v2.1.0/Hearby-Taigi.dmg)（Apple Silicon 的 Mac，macOS 14 以上；已通過 Apple 公證）。打開 DMG，把 Hearby 拖進「應用程式」，或直接雙擊它。

**台語版**＝同一個 Hearby，「聽得懂台語（國台混講）」預設打開：第一次打開會在背景多下載台語模型（約 1.1 GB），原本的模型沒把握或漏聽的地方交給台語模型再聽一次，台語寫成華語用字。只講國語用一般版就好。兩版共用同一個資料夾與設定，裝哪一版都會取代另一版；裝好後在設定裡隨時可以開關。

**Windows**：到 [Releases](https://github.com/intentionltd888/hearby/releases) 找標題有「Windows」的版本，下載 `Hearby-Setup.exe`（目前 1.1.1：[直接下載](https://github.com/intentionltd888/hearby/releases/download/win-v1.1.1/Hearby-Setup.exe)；Windows 10 22H2／Windows 11，x64）。安裝檔沒有數位簽章：Windows 會跳「Windows 已保護您的電腦」→ 按「其他資訊」→「仍要執行」。不需要系統管理員權限，會自動更新。
Windows 台語版：[**下載 Hearby-Taigi-Setup.exe**](https://github.com/intentionltd888/hearby/releases/download/taigi-win-v1.2.1/Hearby-Taigi-Setup.exe)（1.2.1）。裝法一樣；裝在一般版上面會換成台語版，紀錄、設定、模型都留著，之後從台語版自己的版本更新。只有處理器、沒有顯示卡的電腦，台語講得多的會議聽打會多花不少時間。

所有版本在 [Releases](https://github.com/intentionltd888/hearby/releases)。哪些東西會離開你的電腦，寫在 [PRIVACY.md](PRIVACY.md)。

## 授權

這個倉只放發佈版的安裝檔與說明，原始碼不公開。已發佈的版本照 `LICENSE` 授權。Hearby 的標記、字標與圖示是商標，不在 LICENSE 範圍（見 `TRADEMARK.md`）。
第三方元件見 `THIRD-PARTY.md`（Windows 版見 `THIRD-PARTY-WINDOWS.md`）；隱私見 `PRIVACY.md`。
