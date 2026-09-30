# THIRD-PARTY（隨 Windows 安裝檔一起發的第三方元件）

Hearby for Windows 的安裝檔裡，除了 Hearby 自己的程式（MIT，見 LICENSE），還帶了下面這些元件。除了微軟的 C++ 執行階段與漢字轉拼音資料（Unicode License v3），全部是 MIT 授權；MIT 與 Unicode 授權全文附在本檔最後。C++ 執行階段四個檔是微軟簽章的原檔、未經修改，取自微軟官方的 Visual C++ 可轉散發套件（`windows/build.sh` 固定版本並逐檔核對 SHA-256），依 Visual Studio 授權條款的可散發程式碼規定隨附。

| 元件 | 版本 | 授權 | 著作權 | 用途 |
|---|---|---|---|---|
| .NET 執行環境（含 WPF、Windows Forms） | 10.0 | MIT | © .NET Foundation and Contributors | 程式執行環境（自帶，使用者不用另外裝 .NET） |
| NAudio（NAudio.Core、NAudio.Wasapi） | 3.1.0 | MIT | © Mark Heath | 錄音（WASAPI 麥克風與系統聲）、Media Foundation 轉檔 |
| Whisper.net（含 Whisper.net.Runtime 三種：CPU、CPU 無 AVX、Vulkan） | 1.9.1 | MIT | © sandrohanea | 聽打引擎的 .NET 介面與原生元件 |
| whisper.cpp、ggml（由 Whisper.net 的原生元件帶入） | 1.8.x | MIT | © The ggml authors | 聽打引擎本體 |
| Velopack | 1.2.158 | MIT | © Velopack Ltd. | 安裝、更新、解除安裝 |
| 漢字轉拼音資料（Unicode CLDR 的 Han-Latin 轉寫，在 Mac 上經 `CFStringTransform` 產生成 `PinyinData`，編進 Hearby.Core） | CLDR（macOS 內建） | **Unicode License v3**（全文見本檔最後） | © Unicode, Inc. | 讀音比對（名冊名字的聽錯寫法） |
| Microsoft Visual C++ 2015–2022 執行階段（`msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`、`vcomp140.dll`，x64） | 14.44.35211 | Microsoft Visual Studio 授權條款的「可散發程式碼」（**不是 MIT**） | © Microsoft Corporation | 聽打引擎的原生元件要用；放在 Hearby.exe 旁邊，使用者不用另外裝 |

使用者機器上另外下載、不在安裝檔裡的：

| 項目 | 授權 | 來源 | 用途 |
|---|---|---|---|
| Whisper 模型權重（ggml 轉檔版 `ggml-large-v3-turbo-q5_0.bin`） | MIT（© OpenAI；ggml 轉檔 © The ggml authors） | Hugging Face `ggerganov/whisper.cpp` | 聽打模型，第一次設定時下載並核對 SHA-256 |

沒有隨附任何字型檔（介面用 Windows 內建的微軟正黑體與 Segoe UI）。GPU 加速用的是顯示卡驅動程式自帶的 Vulkan，不隨附 Vulkan 元件。

Hearby 的標誌、字標與精靈首頁照片是商標與攝影資產，不在 MIT 範圍，條款見 `Sources/HearbyUI/Resources/Brand/TRADEMARK.md`。

---

## MIT License（上表 MIT 元件適用；著作權行見上表）

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Unicode License v3（漢字轉拼音資料）

```
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 2016-2025 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.

SPDX-License-Identifier: Unicode-3.0
```
