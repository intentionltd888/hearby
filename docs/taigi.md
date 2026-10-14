# 台語辨識（國台混講）——研究與實測

> 起因：使用者問「Hearby 有台語辨識嗎？跟長輩開會偶爾講台語，講國語有時又變台灣國語。」
> 結論先講：**Hearby 原本的聽打模型（whisper large-v3-turbo）聽台語，字錯率約六成，等於聽不懂。**
> 這份文件記錄：網路上已經有人做的（2026-10 盤點）、我們怎麼選、實測數字、Hearby 版怎麼接。

## 1. 已經有人做的

### 1.1 開放權重的模型

| 模型 | 誰做的、何時 | 架構 | 台語 | 授權 | 能不能直接接 Hearby |
|---|---|---|---|---|---|
| **Breeze-ASR-26**（BreezeASR-Taigi） | 聯發創新基地＋陽明交大語音 AI 中心，2026-04（論文 arXiv 2603.19259） | Whisper large-v2 微調，約 1 萬小時合成台語語音（含國台夾雜） | ✅ 台語聲音 → **華語用字**（不是台文） | Apache-2.0 | ✅ Whisper 架構，轉成 whisper.cpp 格式就能用 |
| Breeze-ASR-25（Twister） | 聯發創新基地，2025-06 | Whisper large-v2 微調 | ❌ 台灣口音國語＋中英夾雜；台語 CER 約 50% | Apache-2.0 | ✅ |
| Taiwan Tongues ASR CE | 數位部數位產業署（台灣大哥大執行），2025-10 起 | Whisper large-v2 微調，CTranslate2 格式 | ✅ 國台客英（語言碼 `nan`） | **TRAIL**（LGPL 式「改了要開源」＋負責任使用條款） | 要另轉格式；授權要另外評估；沒公布字錯率 |
| NUTN Whisper-Taiwanese v0.5 | 臺南大學，2025-06 | Whisper large-v3-turbo 微調，約 90 小時（教材＋教育部辭典） | ✅ 以教材為主 | **CC BY-NC**（不可商用） | 授權不行 |
| Qwen3-ASR 1.7B／0.6B | 阿里通義，2026-01 | 自家架構（非 Whisper） | ⚠ 列了「閩南語」（偏中國閩南腔、簡體輸出） | Apache-2.0 | ❌ 不是 Whisper，接不進 whisper.cpp；之後可另外測 |
| 其他小模型 | linshoufan whisper-small nan-tw（Common Voice）、ga642381/Taiwanese-Whisper（TAT、輸出台羅）、CLiFT-ASR（ROCLING 2025 研究） | small／base 級 | ✅ | 各異 | 準確度遠不如上面幾個 |
| Meta Omnilingual ASR | Meta，2025-11 | 1600+ 語言、可零樣本 | ❓ 查不到 `nan` 有沒有在訓練語言表 | Apache-2.0 | ❌ |

### 1.2 商用服務

| 服務 | 台語 | 備註 |
|---|---|---|
| 雅婷逐字稿（台灣 AI 實驗室） | ✅ | 官方 benchmark CER 32.11%；API 約每小時 NT$96–144（第三方整理） |
| 教育部台灣台語輸入法（語音輸入） | ✅ 輸出台文 | 官方 benchmark 換成華語後 CER 30.70% |
| Gemini 3 Flash | ✅ 輸出台文 | 官方 benchmark 換成華語後 CER 32.52% |
| Qwen3-ASR-Flash（雲端） | ⚠ 閩南語 | 付費 API |
| Google Chirp、Azure Speech | ❓ | 查不到 nan-TW |

> Breeze-ASR-26 官方 benchmark：行政院廣播公益廣告 30 組台華平行音檔，平均 CER——Breeze-ASR-26 **30.13%**、教育部輸入法 30.70%、雅婷 32.11%、Gemini 3 Flash 32.52%、Breeze-ASR-25 49.99%。
> 因為台語跟華語不是一對一（意思對、用詞不同也算錯），CER 不會到 0，只適合比相對好壞。

### 1.3 GitHub 上拿 Breeze-ASR-26 做東西的（2026-10）

| 專案 | 做什麼 | 跟我們有關的發現 |
|---|---|---|
| thc1006/breeze-asr-taigi（29★） | faster-whisper＋Gradio 網頁、CLI、Docker，4 GB 顯卡能跑 | 最多人用的包裝 |
| JK-Tian/breeze-asr-taigi | **台語會議紀錄系統**：Breeze-26＋pyannote 分講者＋LLM 修錯字＋出 Obsidian md | 最像 Hearby 的；但整檔只用台語模型 |
| yazelin/taigi-caption | 手機講台語、螢幕即時出中文字幕（PWA） | 自己拿 14 段行政院真人台語廣告量 CER ≈ 30%；錯例：「駕駛」→「教師」 |
| SiqYin/taigi-asr-desktop | Tauri 包的 Windows 桌面版 | — |
| pondahai/ggml-breeze-asr-26-webui、breeze-asr-hub | whisper.cpp 跑在 Jetson | **實測：Breeze-26 在純國語會議上開頭幻聽、整段漏掉主席致詞；英文會被翻成中文。國語為主的錄音他們改回 Breeze-25** |
| 社群轉檔 | weemed（GGML q4/q5、CT2、ONNX）、paulpengtw（CT2）、doggy8088（MLX 4bit） | weemed 的 q5_0 跟我們從官方權重自己轉的 **sha256 完全一樣**（見 §3） |

### 1.4 資料集

- Common Voice nan-tw（v25，2026-03）：約 24 小時、299 人、CC0。
- TAT（Taiwanese Across Taiwan）：學界最常用，但不是開放授權。
- SuiSiann：TTS 語料、非商用。
- Taiwan Tongues 台語資料集：約 3.2 萬筆，TRAIL 授權。
- **行政院廣播公益廣告月包**：每月公開，同一則廣告有華語、臺語、客語版＋腳本——官方 benchmark 的來源，我們的實測也用它（`scripts/taigi/psa-fetch.sh`）。

### 1.5 沒人解決的那一塊

大家的做法都是「整個檔案選一顆模型」：台語檔用 Breeze-26、國語檔用一般模型。
**但真實的會議是混著講的**——主要講國語，偶爾跟長輩講幾句台語。Whisper 沒有台語的語言代碼（只有 `zh`），
沒辦法靠它自己的語言判斷分流；整檔用台語模型又會把國語段聽壞（pondahai 的實測）。
Hearby 版要做的就是這一塊：**同一場會裡，國語段用原本的模型、台語段換台語模型**。

## 2. 我們選什麼、為什麼

**Breeze-ASR-26**：唯一同時符合「台語準」「Apache-2.0 可商用」「Whisper 架構、直接跑在 Hearby 現有的 whisper.cpp 上」三條的。

- Taiwan Tongues（數位部）：TRAIL 授權有「改了要開源」加使用條款，要另外評估；也沒公布字錯率。先不用。
- NUTN：非商用授權。Qwen3-ASR：不是 Whisper 架構，要另接一套引擎（之後可以當第二候選再測）。
- 模型檔：我們從聯發科官方權重（Hugging Face 版本 `7b99268`，兩個權重檔的 sha256 都對過）自己轉成 whisper.cpp 格式再量化成 q5_0
  （`scripts/taigi/convert-breeze.sh`），成品 sha256 `60f25e3a…`——**跟社群 weemed/Breeze-ASR-26-GGML 的 q5_0 逐位元組相同**。
  所以 Hearby 直接從那個倉（釘版本）下載、用這個 sha256 驗；來源一路追得回官方權重。
- 量化：q5_0（1.0 GB）、q8_0（1.5 GB）、f16（2.9 GB）在台語上字錯率 41.7%／39.7%／40.4%，速度一樣。取最小的 q5_0。

## 3. 實測

素材：行政院廣播公益廣告月包（113-02、115-07～10），**22 組同一則廣告的華語版＋臺語版**。
標準答案＝華語版實際講的內容（turbo 初稿、對照官方腳本逐條校正，`scripts/taigi/refs.tsv`）；臺語版比的也是這份（台語模型輸出的是華語用字）。
CER 比的是去標點後的字；數字寫法不算錯（6月30號＝六月三十號）；兩邊都套 Hearby 的幻聽濾網。

### 3.1 單一語言（每段 30 秒）

| 模型 | 華語版 CER | 臺語版 CER |
|---|---|---|
| whisper large-v3-turbo（Hearby 原本） | 3.4% | **59.8%** |
| Breeze-ASR-26 q5_0 | **24.7%** | 41.7% |

turbo 聽台語幾乎不能用；台語模型聽國語錯很多（跟 pondahai 的觀察一致）。所以**不能整場換模型**，要分段用。

### 3.2 國台混講（把廣告接成 2.5～3 分鐘的帶子，Hearby 實際流程端到端）

七捲：四捲「四段國語夾一段台語」（主要講國語、偶爾跟長輩講台語），三捲「國台輪流」。
跑法：`Hearby --import 帶子.wav --provider none`（只要逐字稿），台語關／開各一次；CER 用整捲對齊後，錯字歸到它對到的那一則廣告，分出國語部分與台語部分。

| 測試帶 | Hearby 原本：整捲／國語部分／台語部分 | 聽得懂台語：整捲／國語部分／台語部分 |
|---|---|---|
| 四國一台 1 | 22.8%／1.3%／94.9% | **5.1%／1.3%／18.1%** |
| 四國一台 2 | 53.5%／45.7%／88.9% | 30.7%／28.5%／41.0% |
| 四國一台 3 | 10.5%／3.5%／42.0% | 11.3%／3.5%／46.2% |
| 四國一台 4 | 11.7%／4.2%／44.1% | 8.2%／4.2%／25.2% |
| 國台輪流 1 | 45.2%／28.6%／60.3% | 32.7%／5.7%／57.2% |
| 國台輪流 2 | 58.6%／41.5%／74.9% | 50.1%／41.2%／58.7% |
| 國台輪流 3 | 39.2%／32.1%／46.4% | 16.7%／4.5%／29.2% |
| **平均** | **34.5%／22.4%／64.5%** | **22.1%／12.7%／39.4%** |

- 台語部分錯字率從 64.5% 降到 39.4%，跟官方 benchmark 上 Breeze-ASR-26 的 30%、雅婷的 32% 同一個量級。
- 國語部分也變好（22.4% → 12.7%）：**turbo 在長錄音裡會整段跳過**（有幾則廣告只寫到 12～28% 的內容），台語模式把「有人聲但沒出字」的地方也送去重聽，順便補回來。
- 一捲變差 0.8 個百分點（四國一台 3：台語那段台語模型也聽錯）；國台輪流 2 有幾則廣告兩顆模型都錯很多（台語模型在那裡吐出「（請看資訊簡介）」這類幻聽，把握也低，所以沒換）。
- **純國語的真實會議**（22 分鐘，只看統計、不看內容）：開著台語模式，約 4.5% 的時間換成台語模型的字，跟原本的逐字稿差 3.6% 的字（有改對也有改錯）。
  所以這個開關**預設關**，會講台語的場合才開。
- 時間（M4 Max）：2.5 分鐘的帶子 15 秒 → 20～50 秒；22 分鐘的真實會議 60 秒 → 62 秒（只有沒把握的地方多聽）。

模擬（`bench.py report`，mini 上同一批帶子）的總表，可以看各種做法的差別：

| 做法 | 整捲 | 國語部分 | 台語部分 |
|---|---|---|---|
| Hearby 原本（只用 turbo） | 34.5% | 21.3% | 63.1% |
| 整場只用台語模型 | 37.9% | 27.4% | 59.3% |
| 整場兩顆都跑、時間窗合併（台語模型要多跑六成時間） | 21.7% | 13.0% | 41.7% |
| 理想分流（事先知道哪段是台語） | 27.1% | 20.8% | 42.5% |
| **Hearby 版：只送沒把握的地方** | **17.5%** | **8.2%** | **38.3%** |

## 4. Hearby 版怎麼做（`Sources/HearbyCore/Speech/Taigi.swift`）

1. 主模型（turbo）照舊聽打每一片（15 分鐘），多吐每個字的機率（`-ojf`）。
2. 找要重聽的地方：**平均 log 機率 < −0.3 的段落**（turbo 聽國語時中位數 −0.13、聽台語時 −0.61），加上**有人聲但 turbo 沒出字的空檔**（≥ 2 秒、三成以上的 100 ms 格超過 Hearby 原本的靜音線）。相鄰的併起來、前後墊 0.2 秒。
3. 每一截存一個小檔，**一次呼叫** whisper-cli 跑台語模型（每個 `-f` 配一個 `-of`，模型只載入一次）。
   台語模型不切時間戳（每 30 秒只吐一段字），所以不能把幾截拼成一檔再切回來——這是第一版踩到的坑。
4. 每一截決定換不換：turbo 在截內的字沒把握（< −0.3）而且台語模型高出 0.2；或 turbo 漏聽（台語模型的字 ≥ turbo 的 1.5 倍＋10 字，且台語模型 > −0.5）；
   或 turbo 整截沒字、台語模型 > −0.5。換就整截換，講者沿用那一軌。
5. 台語模型的字：中文字之間的空格換成「，」；它在換氣處會吐「惜」「惜惜」，單獨成句的拿掉（真實會議一場 21 次）。
6. 紀錄表頭寫一行「約 N 秒原本的模型沒把握或漏聽（多半是台語），改用台語模型聽打」。

設定頁「聽得懂台語（國台混講）」一張卡：打開會在背景下載模型（1.1 GB，可續傳、驗 sha256）；命令列 `Hearby --taigi on|off`；`--doctor` 多一項。

## 5. 還沒做、已知限制

- 只有 macOS 版；Windows 版（C#）還沒接。
- 輸出是**華語用字**，不是台文（教育部台文、台羅）。聯發科說台文版還在做。
- 台語模型對人名、專有名詞、地方腔調會錯（社群實測：「駕駛」→「教師」）；Hearby 的名冊與整理階段的 AI 會再修一部分，但不保證。
- 「台灣國語」（帶台語腔的國語）主要還是 turbo 在聽；這次的測試素材是標準國語，沒量到這一種。
- 測試素材是廣播廣告（有配樂、一人一句），不是真的會議；真的國台混講會議要錄幾場來量。

## 6. 重跑

```bash
bash scripts/taigi/psa-fetch.sh <工作夾>/psa                       # 行政院月包（約 110 MB）
python3 scripts/taigi/bench.py prep <工作夾>/psa/x* --out <工作夾>/ds   # 22 組華／臺配對、轉 16 kHz
python3 scripts/taigi/bench.py mix <工作夾>/ds                       # 7 捲混講帶
python3 scripts/taigi/bench.py run <工作夾>/ds turbo ggml-large-v3-turbo.bin
python3 scripts/taigi/bench.py run <工作夾>/ds breeze ggml-breeze-asr-26-q5_0.bin
python3 scripts/taigi/bench.py score <工作夾>/ds turbo breeze
python3 scripts/taigi/bench.py selective <工作夾>/ds sel turbo ggml-breeze-asr-26-q5_0.bin
python3 scripts/taigi/bench.py report <工作夾>/ds turbo breeze --selective sel
bash scripts/taigi/convert-breeze.sh <工作夾>                        # 從官方權重重做模型檔（約 6 GB 下載）
```

需要 ffmpeg、whisper-cli；繁簡轉換有 `opencc-python-reimplemented` 就用（沒有也能跑，但簡體輸出會被多算錯）。
