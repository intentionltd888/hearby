# AGENTS.md — 給幫使用者把 Hearby for Windows 接好的 AI（Claude Code、Codex、Cursor、任何 agent）

你正在幫一個人把 **Hearby**（會議紀錄，開源）在他的 Windows 電腦上接好。
目標只有一個：**他開會前按一下、開完會資料夾裡就有一份紀錄，而且你（他的 AI）讀得到那份紀錄。**
驗收＝這件事真的發生，不是「某個檢查通過」。全程不要動他的其他設定、不要刪東西、不要幫他填 API 金鑰。

這份檔隨 app 一起裝在 `%LOCALAPPDATA%\HearbyApp\current\AGENTS.md`，沒有原始碼倉也讀得到。

## 0. 第一件事：跑體檢（不要自己翻資料夾猜）

Hearby.exe 是視窗程式：在 PowerShell 裡要接 `| Out-Host`，PowerShell 才會等它印完。

```powershell
& "$env:LOCALAPPDATA\HearbyApp\current\Hearby.exe" --doctor --deep | Out-Host
```

七行：系統／麥克風／系統聲／聽打模型／整理方式／磁碟／資料夾。每一行「缺」對應下面一節。

## 1. 裝 app

- 從 GitHub Releases 下載 `Hearby-Setup.exe`，雙擊。不需要系統管理員權限，裝在 `%LOCALAPPDATA%\HearbyApp`，開始功能表與桌面各一個捷徑。
- 安裝檔沒有數位簽章：Windows 會跳「Windows 已保護您的電腦」→ 按「其他資訊」→「仍要執行」。這一步只有他本人能按。
- 打開後 app 走四頁精靈：歡迎（背景下載聽打模型，約 0.6 GB）→ 讓它聽得到 → 紀錄要誰寫 → 試一次。可以陪他走。

## 2. 權限：Windows 不會跳視窗問，只有一個開關

| 項目 | 何時需要 | 怎麼開 |
|---|---|---|
| 麥克風 | 必要 | 設定 › 隱私權與安全性 › 麥克風：「麥克風存取」與「讓傳統型應用程式存取您的麥克風」都要開（`ms-settings:privacy-microphone`） |
| 電腦裡的聲音 | 只有「線上會議」情境 | 不需要任何權限（Windows 的 loopback 錄音） |

## 3. 整理方式：優先用他已經有的訂閱，不用 API 金鑰

| 順位 | 條件 | 怎麼接 | 怎麼驗 |
|---|---|---|---|
| 1 | 有 Claude 訂閱 | 精靈第 2 頁或設定「交給我的 Claude 整理」→ app 用官方指令裝 Claude Code（`irm https://claude.ai/install.ps1 \| iex`，不用管理員）、開瀏覽器登入；網頁給代碼就貼回 app | `& "$env:USERPROFILE\.local\bin\claude.exe" auth status` 有 `"loggedIn": true` |
| 2 | 自己裝了 Ollama／LM Studio | 設定「交給本機模型整理」→ 讀取模型 → 選一個 → 存 | 設定頁那列是「可以用」 |
| 3 | 都沒有 | 「先只要逐字稿」：有分段、時間戳，不用帳號 | 錄一段出 md |

ChatGPT（Codex）在 Windows 版還沒開放：macOS 版把它關在外層沙箱裡跑，Windows 上還沒有同等的做法。
登入永遠走官方 CLI 自己的流程；app 不做登入畫面、不收帳密（`COMPLIANCE.md`）。

## 4. 紀錄在哪、你怎麼讀

`%USERPROFILE%\Hearby\` 就是專案：`CLAUDE.md`／`AGENTS.md` 是入口，`memory\` 五個檔是他的會議記憶（設定裡打開「記憶」才會寫），`會議\<日期_時間_標題>\` 是每一場。
在那個資料夾打開你自己，第一句就能講出上一場的三個待辦。討論完的新決定寫回 `memory\THREADS.md`、待辦寫進 `OPEN.md`；
他手改過的行不要動、不確定的標 `[[?]]`、不要發明他沒說過的話。

設定、模型、錄音工作檔在 `%LOCALAPPDATA%\Hearby\`；紀錄檔在 `%LOCALAPPDATA%\Hearby\Logs\hearby.log`。

## 5. 驗收

1. 他按工作列右下角那顆引號 ” 圖示（沒看到就先按 ^）→ 面板跳出來 → 按中間的大圓 → 講兩句 → 再按一次。
2. `%USERPROFILE%\Hearby\會議\` 多出一個夾，裡面有 `.m4a` 與 `.md`。
3. 你在 `%USERPROFILE%\Hearby\` 讀得到那份 md。
