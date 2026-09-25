# COMPLIANCE.md — 接第三方 AI 的四條紅線（fork 與改作也適用）

1. **Claude Code 執行檔不能動**：只 spawn 使用者自己安裝的官方版本，不移除、停用、限制任何內建登入方式。
2. **不代付、不轉售、不中介用量**：每個使用者用自己的憑證，帳單直接算他自己頭上。本產品無金流。
3. **登入必須走官方自己的流程**：app 只呼叫官方 CLI 的登入指令並開系統瀏覽器；**永遠不在 app 裡做登入畫面收帳密或 session token**。
4. **宣傳只能用純文字提**：可以寫「接上你自己的 Claude Code 或 ChatGPT」；不可把 Claude／Anthropic／OpenAI 的名字或標誌放進產品名、功能名、圖示或任何暗示背書的地方。功能叫「用我的訂閱」。

Windows 版：Claude Code 用 Anthropic 官方的安裝指令與官方 `claude auth login`（瀏覽器登入、代碼貼回 CLI 自己的提示），app 不經手任何憑證；ChatGPT（Codex）在 Windows 版不提供，因為還沒有等同 macOS 外層沙箱的隔離。<!-- windows -->

用量誠實：兩小時會議會吃掉訂閱額度；README 與精靈第 3 頁要事先講一場大概吃多少。
