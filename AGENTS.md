# AGENTS.md — 給幫使用者把 Hearby 接好的 AI（Claude Code、Codex、Cursor、任何 agent）

你正在幫一個人把 **Hearby**（macOS 會議紀錄，開源）在他的 Mac 上接好。
目標只有一個：**他開會前按一下、開完會資料夾裡就有一份紀錄，而且你（他的 AI）讀得到那份紀錄。**
驗收＝這件事真的發生，不是「某個檢查通過」。全程不要動他的其他設定、不要刪東西、不要幫他填 API 金鑰。

這份檔隨 app 一起裝在 `/Applications/Hearby.app/Contents/Resources/AGENTS.md`，沒有原始碼倉也讀得到。

## 0. 第一件事：跑體檢（不要自己 ls 猜）

```bash
/Applications/Hearby.app/Contents/MacOS/Hearby --doctor --deep
```

七行：系統／麥克風／系統聲／聽打模型／整理方式／磁碟／資料夾。每一行「缺」對應下面一節。

## 1. 裝 app

- 有 `Hearby-*.dmg`：掛載、把 `Hearby.app` 拖進 `/Applications`，從那裡打開。
- 只有原始碼：`bash scripts/vendor-fetch.sh && bash build.sh && open build/Hearby.app`（要先 `xcode-select --install`）。

打開後 app 走四頁精靈：歡迎（背景下模型）→ 權限 → 整理方式 → 試錄。可以陪他走。

## 2. 權限：只有他本人能按

| 權限 | 何時需要 | 怎麼開 |
|---|---|---|
| 麥克風 | 必要 | 第一次錄音系統會問 → 按「允許」 |
| 系統聲音 | 只有「線上會議」情境 | 精靈會帶去系統設定；同一個房間開會不需要 |

## 3. 整理方式：優先用他已經有的訂閱，不用 API 金鑰

| 順位 | 條件 | 怎麼接 | 怎麼驗 |
|---|---|---|---|
| 1 | 有 Claude 訂閱 | 精靈第 3 頁「用我的訂閱」卡 → app 自己裝官方 Claude Code、開瀏覽器登入 | `claude auth status` 有 `loggedIn: true` |
| 2 | 有 ChatGPT 訂閱 | 同一張卡 → app 自己裝官方 Codex、開瀏覽器登入。**已登入的機器千萬別再跑 `codex login`** | `codex login status` 印 Logged in |
| 3 | 都沒有 | 「只要逐字稿」卡：有分段、標題、時間戳，不用帳號 | 錄一段出 md |

登入永遠走官方 CLI 自己的流程；app 不做登入畫面、不收帳密（`COMPLIANCE.md`）。

## 4. 紀錄在哪、你怎麼讀

`~/Hearby/` 就是專案：`CLAUDE.md`／`AGENTS.md` 是入口，`memory/` 五個檔是他的會議記憶，`會議/<日期_時間_標題>/` 是每一場。
在 `~/Hearby/` 打開你自己，第一句就能講出上一場的三個待辦。討論完的新決定寫回 `memory/THREADS.md`、待辦寫進 `OPEN.md`；
他手改過的行不要動、不確定的標 `[[?]]`、不要發明他沒說過的話。

## 5. 驗收

1. 他按選單列那顆引號圖示 → 面板掉下來 → 按開始 → 講兩句 → 按停止。
2. `~/Hearby/會議/` 多出一個夾，裡面有 `.m4a` 與 `.md`。
3. 你在 `~/Hearby/` 讀得到那份 md。
