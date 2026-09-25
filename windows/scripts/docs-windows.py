#!/usr/bin/env python3
"""docs-windows.py <repo root> — add the Windows version to the root documents (README, PRIVACY, COMPLIANCE, TESTING, AGENTS).
Idempotent: a document that already mentions windows/README.md (or the marker below) is left alone.
Used once when the Windows version was added; kept so the change is reproducible on another branch."""
import sys, pathlib

root = pathlib.Path(sys.argv[1])
MARK = "<!-- windows -->"
WIN_TAG = "win-v1.0.0"
REPO = "https://github.com/intentionltd888/hearby"


def patch(name, edits):
    p = root / name
    s = p.read_text(encoding="utf-8")
    if MARK in s:
        print(f"skip {name} (already has the Windows part)")
        return
    for anchor, add, where in edits:
        if anchor not in s:
            raise SystemExit(f"{name}: anchor not found: {anchor[:60]}")
        if where == "after":
            s = s.replace(anchor, anchor + add, 1)
        elif where == "before":
            s = s.replace(anchor, add + anchor, 1)
        else:  # replace
            s = s.replace(anchor, add, 1)
    p.write_text(s, encoding="utf-8")
    print(f"patched {name}")


patch("README.md", [
    ("開的會越多，它越懂你在做什麼。中文英文夾著講也聽得準，錄音留著隨時點回去聽，不用月費。\n",
     "\nmacOS 與 Windows 都有。" + MARK + "\n", "after"),
    ("還沒做：自動更新、會前準備自動帶入。", "還沒做：自動更新（macOS 版；Windows 版有）、會前準備自動帶入。", "replace"),
    ("所有版本在 [Releases](https://github.com/intentionltd888/hearby/releases)。",
     f"**Windows**：到 [Releases]({REPO}/releases) 找標題有「Windows」的版本，下載 `Hearby-Setup.exe`"
     f"（目前 1.0.0：[直接下載]({REPO}/releases/download/{WIN_TAG}/Hearby-Setup.exe)；Windows 10 22H2／Windows 11，x64）。"
     "安裝檔沒有數位簽章：Windows 會跳「Windows 已保護您的電腦」→ 按「其他資訊」→「仍要執行」。"
     "不需要系統管理員權限，會自動更新。Windows 版的說明與跟 macOS 版的差別見 [windows/README.md](windows/README.md)。\n\n", "before"),
    ("scripts/             check-clean", "windows/             Windows 版（C#／WPF）：Hearby.Core（核心的 C# 版）、Hearby.App（殼）、合約測試、build.sh——見 windows/README.md\n"
     "contract/            macOS 核心在固定輸入下的輸出：Windows 核心照著逐字比對（contract/README.md）\n", "before"),
    ("第三方元件見 `THIRD-PARTY.md`；", "第三方元件見 `THIRD-PARTY.md`（Windows 版見 `windows/THIRD-PARTY-WINDOWS.md`）；", "replace"),
])

patch("PRIVACY.md", [
    ("Hearby 沒有自己的伺服器、沒有帳號、沒有遙測、沒有自動更新。",
     "Hearby 沒有自己的伺服器、沒有帳號、沒有遙測。macOS 版沒有自動更新；Windows 版會向 GitHub 查新版（見最後一節）。" + MARK, "replace"),
    ("「不會上傳」不是本產品的賣點；", """## Windows 版多的與不一樣的

- **資料位置**：紀錄在 `%USERPROFILE%\\Hearby\\`；設定、聽打模型、錄音工作檔在 `%LOCALAPPDATA%\\Hearby\\`，紀錄檔在 `%LOCALAPPDATA%\\Hearby\\Logs\\`。
- **查新版**：打開一分鐘後、之後每 12 小時，向 GitHub（`api.github.com` 與 GitHub 的下載位址）查這個專案有沒有新的 Windows 版，有就先下載好。送出去的只是一般的網頁請求（對方看得到你的 IP），不帶任何紀錄、設定或帳號資料。設定 → 更新 可以關掉自動檢查。
- **聽打模型**從 Hugging Face 下載，Windows 版用的是量化版（約 0.6 GB），下載後驗大小與 SHA-256。
- **裝 Claude Code** 執行的是 Anthropic 官方的 Windows 安裝指令（`irm https://claude.ai/install.ps1 | iex`），只在你按「安裝」時。ChatGPT（Codex）在 Windows 版不提供。
- **匯出 PDF** 會在背景啟動這台電腦的 Microsoft Edge 排版；那一頁不准跑任何程式碼、不准載入外部資源。Edge 自己的連線依微軟的設定。
- **「跟 Claude 討論」**：有裝 Claude 桌面版就開它，沒有就在 PowerShell 裡開 Claude Code；問題也會放進剪貼簿。
- **「線上會議」**錄的是 Windows 預設播放裝置放出來的所有聲音，跟 macOS 版一樣會包含同時在播的影片與通知音。

""", "before"),
])

patch("COMPLIANCE.md", [
    ("用量誠實：", "Windows 版：Claude Code 用 Anthropic 官方的安裝指令與官方 `claude auth login`（瀏覽器登入、代碼貼回 CLI 自己的提示），app 不經手任何憑證；ChatGPT（Codex）在 Windows 版不提供，因為還沒有等同 macOS 外層沙箱的隔離。" + MARK + "\n\n", "before"),
])

patch("TESTING.md", [
    ("狀態：✅＝已驗", "Windows 版的驗收條目見 [windows/TESTING-WINDOWS.md](windows/TESTING-WINDOWS.md)。" + MARK + "\n\n", "before"),
])

patch("AGENTS.md", [
    ("你正在幫一個人把 **Hearby**", "> 對方用的是 Windows？看 [windows/AGENTS-WINDOWS.md](windows/AGENTS-WINDOWS.md)（安裝後也在 `%LOCALAPPDATA%\\HearbyApp\\current\\AGENTS.md`）。" + MARK + "\n\n", "before"),
])
