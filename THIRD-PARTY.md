# THIRD-PARTY.md（隨 DMG 一起發的第三方元件）

| 元件 | 授權 | 用途 |
|---|---|---|
| whisper.cpp、ggml | MIT | 聽打引擎（`vendor/`，不進 git） |
| Whisper 模型權重（ggml 轉檔版） | MIT | 聽打模型（使用者機器下載） |
| FluidAudio（含 fastcluster、VBx 等，見 `licenses/FluidAudio/`） | Apache-2.0（fastcluster：BSD-2-Clause） | 認聲音：說話人分段（macOS 15 以上；編進 app） |
| 說話人分段模型 FluidInference/speaker-diarization-coreml（pyannote 分段、WeSpeaker 聲紋、BUT Speech@FIT 的 VBx／PLDA，Fluid Inference 轉成 Core ML） | CC-BY-4.0 | 認聲音（使用者機器下載，約 22 MB，打開認聲音後第一次用時） |
| 漢字轉拼音資料（Unicode CLDR 的 Han-Latin 轉寫，經 macOS `CFStringTransform` 產生成 `PinyinData`） | Unicode License v3（© Unicode, Inc.，全文見本檔最後） | 讀音比對（名冊名字的聽錯寫法） |

字型全走系統字，不隨附任何字型檔。

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
