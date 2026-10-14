#!/usr/bin/env python3
"""bench.py — 國台混講聽打實測（開發用，不隨 app 出貨）

素材：行政院「廣播公益廣告月包」——同一則廣告有華語版與臺語版（台語版照華語稿翻講），
這正是 Breeze-ASR-26 官方 benchmark 的素材來源。標準答案＝華語稿（台語聽打輸出的也是華語用字）。

  prep   <月包夾…> --out DIR        找出華／臺成對的廣告，轉成 16 kHz 單聲道 wav，寫 pairs.json
  run    DIR NAME MODEL [--cli X]   用 whisper-cli 聽打 DIR/wav 與 DIR/tapes 下全部 wav（參數同 Hearby）
  drafts DIR NAME                   用 NAME 的華語版輸出寫 refs/<id>.txt 草稿（再對照官方腳本人工校）
  mix    DIR                        組「國台混講」測試帶：tapes/*.wav＋標準答案＋每段語言
  score  DIR NAME…                  單語 CER：每個模型在華語版、臺語版各自的平均字錯率
  hybrid DIR PRIMARY TAIGI          混講帶上比較：只用 PRIMARY、只用 TAIGI、各種合併策略

CER＝編輯距離／標準答案字數（去標點、空白，轉繁體，英文小寫）。台語跟華語不是一對一，
所以台語段的 CER 不會到 0，適合拿來比相對好壞（模型卡也這樣說）。
"""
import argparse, json, os, re, subprocess, sys, time, unicodedata, wave

PROMPT = "以下是台灣繁體中文的會議對話逐字稿。"   # 跟 Hearby Transcript.prompt 一致

try:
    import opencc  # opencc-python-reimplemented；逐字轉（s2tw），不用 s2twp——那個會換詞（程序→程式、支持→支援）
    _cc = opencc.OpenCC("s2tw")
    def to_trad(s): return _cc.convert(s)
except Exception:
    def to_trad(s): return s

# 幻聽濾網：照 Hearby Hallucination.swift 的強片語＋殘字門檻（兩個模型一視同仁）
JUNK = sorted(["謝謝觀看", "謝謝收看", "字幕由", "Amara", "amara.org", "字幕提供", "中文字幕", "MING PAO", "明鏡與點點",
               "字幕志願者", "志願者", "感謝觀看", "感謝收看", "請不吝", "點贊", "轉發", "打賞", "欄目", "點點欄目",
               "優優獨播劇場", "宣優獨播劇場", "獨播劇場", "YoYo Television Series Exclusive", "Television Series Exclusive",
               "字幕:李宗盛", "字幕：李宗盛", "詞:李宗盛", "詞：李宗盛"], key=len, reverse=True)

def strip_junk(text):
    """→ 去掉幻聽片語後的字；剩不到 6 個實字＝整段是幻聽，回空字串"""
    t = to_trad(text)
    for j in JUNK: t = t.replace(j, "")
    t = re.sub(r"[—\-–]+\s*$", "", t).strip()
    return t if sum(ch.isalnum() for ch in t) >= 6 or t == to_trad(text).strip() else ""


# ── 正規化與 CER ──────────────────────────────────────────────
NUM_RUN = re.compile(r"[0-9零〇一二兩三四五六七八九十百千萬點.]+")

def norm(s):
    s = unicodedata.normalize("NFKC", to_trad(s)).lower()
    s = "".join(ch for ch in s if ch.isalnum() or ch == ".")
    return NUM_RUN.sub("#", s)   # 數字寫法不算錯（6月30號＝六月三十號）；一律收成一個記號，數字聽錯算一個字

def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
        prev = cur
    return prev[-1]

def cer(hyp, ref):
    h, r = norm(hyp), norm(ref)
    return edit_distance(h, r) / max(1, len(r))


# ── prep：配對與轉檔 ─────────────────────────────────────────
LANG_ZH = ("華語", "國語", "華國")
LANG_NAN = ("臺語", "台語", "臺國")

def lang_of(name):
    if any(k in name for k in LANG_NAN): return "nan"
    if "客" in name or "自然語" in name: return None
    if any(k in name for k in LANG_ZH): return "zh"
    return None

def title_key(name):
    t = os.path.splitext(name)[0]
    t = re.sub(r"[（(][^)）]*[)）]", "", t)
    for w in LANG_ZH + LANG_NAN + ("客語", "30秒", "篇"):
        t = t.replace(w, "")
    return re.sub(r"[\s_\-－、，,：:]", "", t)

def ffmpeg_wav(src, dst):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", src,
                    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", dst], check=True)

def cmd_prep(a):
    os.makedirs(os.path.join(a.out, "wav"), exist_ok=True)
    pairs, seen = [], set()
    for pack in a.packs:
        found = {}
        for root, _, files in os.walk(pack):
            for f in files:
                if not f.lower().endswith((".mp3", ".wav")): continue
                lg = lang_of(f)
                if lg: found.setdefault(title_key(f), {})[lg] = os.path.join(root, f)
        for key in sorted(found):
            v = found[key]
            if "zh" not in v or "nan" not in v or key in seen: continue
            seen.add(key)
            pid = "p%02d" % (len(pairs) + 1)
            for lg in ("zh", "nan"):
                ffmpeg_wav(v[lg], os.path.join(a.out, "wav", f"{pid}_{lg}.wav"))
            pairs.append({"id": pid, "title": key, "pack": os.path.basename(pack.rstrip("/")),
                          "zh": os.path.basename(v["zh"]), "nan": os.path.basename(v["nan"])})
    json.dump(pairs, open(os.path.join(a.out, "pairs.json"), "w"), ensure_ascii=False, indent=1)
    print(f"{len(pairs)} 組華／臺配對 → {a.out}/pairs.json")


# ── run：whisper-cli 聽打（-ojf 留每個字的機率給合併策略用）────────
def wav_ms(path):
    with wave.open(path) as w: return int(w.getnframes() * 1000 / w.getframerate())

def run_one(cli, model, wav, out_base, threads, extra=()):
    extra = tuple(extra.split()) if isinstance(extra, str) else tuple(extra)
    t0 = time.time()
    r = subprocess.run([cli, "-m", model, "-f", wav, "-l", "zh", "-t", str(threads),
                        "--prompt", PROMPT, "--carry-initial-prompt", "-ojf", "-of", out_base, "-np", *extra],
                       capture_output=True)   # 不解碼：whisper 偶爾吐半個 UTF-8 字
    return time.time() - t0, r.returncode

def cmd_run(a):
    out = os.path.join(a.dir, "runs", a.name); os.makedirs(out, exist_ok=True)
    wavs = []
    for sub in ("wav", "tapes"):
        d = os.path.join(a.dir, sub)
        if os.path.isdir(d): wavs += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".wav")]
    timing = {}
    tf = os.path.join(out, "_timing.json")
    if os.path.exists(tf): timing = json.load(open(tf))
    for w in wavs:
        base = os.path.join(out, os.path.splitext(os.path.basename(w))[0])
        if os.path.exists(base + ".json") and not a.force: continue
        secs, rc = run_one(a.cli, a.model, w, base, a.threads, a.extra)
        timing[os.path.basename(w)] = {"secs": round(secs, 2), "audio_ms": wav_ms(w), "rc": rc}
        print(f"  {os.path.basename(w)}  {secs:.1f}s  rc={rc}", flush=True)
        json.dump(timing, open(tf, "w"), indent=1)
    tot_s = sum(v["secs"] for v in timing.values()); tot_a = sum(v["audio_ms"] for v in timing.values()) / 1000
    print(f"{a.name}: {len(timing)} 檔，聽打 {tot_s:.0f}s／音檔 {tot_a:.0f}s，RTF {tot_s / max(tot_a, 1):.3f}")


# ── 讀 -ojf 的 JSON ───────────────────────────────────────────
def load_segments(path):
    """→ [(from_ms, to_ms, text, mean_logp, n_tokens)]"""
    raw = open(path, "rb").read().decode("utf-8", "replace")
    obj = json.loads(raw)
    segs = []
    for t in obj.get("transcription", []):
        toks = [k for k in t.get("tokens", []) if not k.get("text", "").startswith("[_") and k.get("p") is not None]
        import math
        lp = [math.log(max(k["p"], 1e-6)) for k in toks]
        text = strip_junk(t["text"].strip())
        if not text: continue
        segs.append((t["offsets"]["from"], t["offsets"]["to"], text,
                     sum(lp) / len(lp) if lp else 0.0, len(lp)))
    return segs

def text_of(path):
    return "".join(s[2] for s in load_segments(path))


# ── drafts／score ────────────────────────────────────────────
def cmd_drafts(a):
    pairs = json.load(open(os.path.join(a.dir, "pairs.json")))
    rd = os.path.join(a.dir, "refs"); os.makedirs(rd, exist_ok=True)
    for p in pairs:
        f = os.path.join(rd, p["id"] + ".txt")
        if os.path.exists(f): continue
        txt = to_trad(text_of(os.path.join(a.dir, "runs", a.name, p["id"] + "_zh.json")))
        open(f, "w").write(txt + "\n")
    print(f"草稿寫在 {rd}/（已有的不覆蓋）")

_REFS = None

def ref_of(d, pid, lang="zh"):
    """標準答案在 bench.py 旁的 refs.tsv。臺語版台詞跟華語稿不同的，用 <id>_nan 那一行"""
    global _REFS
    if _REFS is None:
        _REFS = {}
        for line in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "refs.tsv"), encoding="utf-8"):
            if line.startswith("#") or "\t" not in line: continue
            k, v = line.rstrip("\n").split("\t", 1); _REFS[k] = v
    return _REFS.get(f"{pid}_{lang}") or _REFS[pid]

def cmd_score(a):
    pairs = json.load(open(os.path.join(a.dir, "pairs.json")))
    rows = []
    print("| 模型 | 華語版 CER | 臺語版 CER |\n|---|---|---|")
    for name in a.names:
        cz, cn = [], []
        for p in pairs:
            for lg, acc in (("zh", cz), ("nan", cn)):
                j = os.path.join(a.dir, "runs", name, f"{p['id']}_{lg}.json")
                if os.path.exists(j): acc.append(cer(text_of(j), ref_of(a.dir, p["id"], lg)))
        rows.append((name, cz, cn))
        print(f"| {name} | {100 * sum(cz) / max(1, len(cz)):.1f}% ({len(cz)}) | {100 * sum(cn) / max(1, len(cn)):.1f}% ({len(cn)}) |")
    if a.detail:
        for p in pairs:
            cells = []
            for name in a.names:
                for lg in ("zh", "nan"):
                    j = os.path.join(a.dir, "runs", name, f"{p['id']}_{lg}.json")
                    cells.append(f"{100 * cer(text_of(j), ref_of(a.dir, p['id'], lg)):.0f}" if os.path.exists(j) else "-")
            print(p["id"], p["title"][:16], " ".join(cells))


# ── mix：國台混講測試帶 ───────────────────────────────────────
GAP_MS = 700

def read_pcm(path):
    with wave.open(path) as w: return w.readframes(w.getnframes())

def write_wav(path, pcm):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(pcm)

def cmd_mix(a):
    """兩種帶：
       alt*  華、臺輪流（會議裡兩種語言一樣多）
       zh4*  四段華語夾一段臺語（Luca 那種：主要講國語，偶爾跟長輩講台語）
       同一則廣告只出現一次（不會同時有它的華語版與臺語版），避免答案互相提示。"""
    pairs = json.load(open(os.path.join(a.dir, "pairs.json")))
    td = os.path.join(a.dir, "tapes"); os.makedirs(td, exist_ok=True)
    gap = b"\x00\x00" * (16 * GAP_MS)
    plans = []
    ids = [p["id"] for p in pairs]
    for k in range(0, len(ids) - 5, 6):        # alt：6 段一捲
        plans.append(("alt%d" % (k // 6 + 1), [(ids[k + i], "zh" if i % 2 == 0 else "nan") for i in range(6)]))
    for k in range(0, len(ids) - 4, 5):        # zh4：5 段一捲，第 3 段是臺語
        plans.append(("zh4_%d" % (k // 5 + 1), [(ids[k + i], "nan" if i == 2 else "zh") for i in range(5)]))
    meta = {}
    for name, items in plans:
        pcm, spans, refs, t = b"", [], [], 0
        for pid, lg in items:
            clip = read_pcm(os.path.join(a.dir, "wav", f"{pid}_{lg}.wav"))
            ms = len(clip) // 32
            spans.append({"id": pid, "lang": lg, "from": t, "to": t + ms})
            refs.append(ref_of(a.dir, pid, lg))
            pcm += clip + gap; t += ms + GAP_MS
        write_wav(os.path.join(td, f"tape_{name}.wav"), pcm)
        meta[f"tape_{name}"] = {"spans": spans, "ref": "".join(refs)}
    json.dump(meta, open(os.path.join(a.dir, "tapes.json"), "w"), ensure_ascii=False, indent=1)
    print(f"{len(plans)} 捲 → {td}")


# ── hybrid：合併策略 ─────────────────────────────────────────
def lang_at(spans, ms):
    for s in spans:
        if s["from"] - GAP_MS // 2 <= ms < s["to"] + GAP_MS // 2: return s["lang"]
    return None

def overlap_text(segs, a, b):
    """另一個模型在 [a,b) 這段時間的字：照重疊比例取整段（段落邊界不同，取重疊過半的）"""
    out = []
    for f, t, txt, lp, n in segs:
        ov = min(b, t) - max(a, f)
        if ov > 0 and ov >= 0.5 * min(t - f, b - a): out.append((f, t, txt, lp, n))
    return out

def strategy_switch(prim, alt, thr):
    """主模型這一段平均 log 機率 < thr → 換成台語模型同時段的字"""
    out, used = [], set()
    routed = []
    for f, t, txt, lp, n in prim:
        if lp < thr:
            for s in overlap_text(alt, f, t):
                if s[0] in used: continue
                used.add(s[0]); out.append(s[2])
            routed.append((f, t, "alt"))
        else:
            out.append(txt); routed.append((f, t, "prim"))
    return "".join(out), routed

def strategy_compare(prim, alt, margin):
    """同一段時間比兩個模型各自的平均 log 機率，台語模型高出 margin 才用它"""
    out, used, routed = [], set(), []
    for f, t, txt, lp, n in prim:
        cand = [s for s in overlap_text(alt, f, t) if s[0] not in used]
        alp = sum(s[3] * s[4] for s in cand) / max(1, sum(s[4] for s in cand)) if cand else -99
        if cand and alp > lp + margin:
            for s in cand: used.add(s[0]); out.append(s[2])
            routed.append((f, t, "alt"))
        else:
            out.append(txt); routed.append((f, t, "prim"))
    return "".join(out), routed

def windows(prim, alt, min_ov=0.3):
    """把兩個模型的段落併成時間窗：重疊超過較短那段 min_ov 的算同一窗（邊界抖動不算重疊）。
    → [(prim 段落索引們, alt 段落索引們)]，照時間排"""
    items = [("p", i, s[0], s[1]) for i, s in enumerate(prim)] + [("a", i, s[0], s[1]) for i, s in enumerate(alt)]
    parent = list(range(len(items)))
    def find(x):
        while parent[x] != x: parent[x] = parent[parent[x]]; x = parent[x]
        return x
    P = [k for k, it in enumerate(items) if it[0] == "p"]; A = [k for k, it in enumerate(items) if it[0] == "a"]
    for i in P:
        for j in A:
            f1, t1 = items[i][2], items[i][3]; f2, t2 = items[j][2], items[j][3]
            ov = min(t1, t2) - max(f1, f2)
            if ov > 0 and ov >= min_ov * max(1, min(t1 - f1, t2 - f2)): parent[find(i)] = find(j)
    groups = {}
    for k in range(len(items)): groups.setdefault(find(k), []).append(k)
    out = []
    for ks in groups.values():
        ps = sorted(items[k][1] for k in ks if items[k][0] == "p"); as_ = sorted(items[k][1] for k in ks if items[k][0] == "a")
        start = min(items[k][2] for k in ks)
        out.append((start, ps, as_))
    return [(ps, as_) for _, ps, as_ in sorted(out)]

def wconf(segs, idx):
    n = sum(segs[i][4] for i in idx)
    return sum(segs[i][3] * segs[i][4] for i in idx) / n if n else None

def strategy_window(prim, alt, low, margin, fill=None, oracle_spans=None, chosen=None):
    """時間窗為單位：主模型這窗的信心 < low，而且台語模型同一窗高出 margin → 整窗用台語模型的字。
    主模型整窗沒字：fill＝None 不補（Hearby 預設），否則台語模型把握 > fill 才補。
    oracle_spans＝給真實語言標記：照真相分流（看分流做到完美能多好）。chosen＝list 的話把選中的段落放進去"""
    out, routed = [], []
    for ps, as_ in windows(prim, alt):
        cp, ca = wconf(prim, ps), wconf(alt, as_)
        if oracle_spans is not None:
            segs_all = [prim[i] for i in ps] + [alt[i] for i in as_]
            mid = (min(s[0] for s in segs_all) + max(s[1] for s in segs_all)) // 2
            use_alt = bool(as_) and lang_at(oracle_spans, mid) == "nan"
        else:
            use_alt = bool(as_) and bool(ps) and cp is not None and ca is not None and cp < low and ca >= cp + margin
            if not ps and as_: use_alt = fill is not None and (ca or -9) > fill
        segs = [alt[i] for i in as_] if use_alt else [prim[i] for i in ps]
        out += [s[2] for s in segs]
        routed += [(s[0], s[1], "alt" if use_alt else "prim") for s in segs]
        if chosen is not None: chosen += segs
    return "".join(out), routed

def window_chosen(prim, alt, low, margin, oracle=None):
    c = []
    strategy_window(prim, alt, low, margin, oracle_spans=oracle, chosen=c)
    return c

def lang_errors(hyp, parts):
    """整捲聽打結果跟整捲答案做編輯距離對齊，每個錯算到它對到的那一截（插入算到前一個答案字）。
    parts＝[(語言, 那一截的答案)…] → {語言: (錯字數, 答案字數)}。用中點分段會因為一段字跨過兩則廣告而算錯，所以用對齊"""
    H = norm(hyp); R, lab = "", []
    for lg, txt in parts:
        n = norm(txt); R += n; lab += [lg] * len(n)
    n, m = len(H), len(R)
    D = [[0] * (m + 1) for _ in range(n + 1)]
    for j in range(m + 1): D[0][j] = j
    for i in range(1, n + 1):
        D[i][0] = i; hi = H[i - 1]; row, prev = D[i], D[i - 1]
        for j in range(1, m + 1):
            row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (hi != R[j - 1]))
    err = {lg: 0 for lg in set(lab)}
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and D[i][j] == D[i - 1][j - 1] + (H[i - 1] != R[j - 1]):
            if H[i - 1] != R[j - 1]: err[lab[j - 1]] += 1
            i -= 1; j -= 1
        elif j > 0 and D[i][j] == D[i][j - 1] + 1:
            err[lab[j - 1]] += 1; j -= 1          # 漏字
        else:
            err[lab[max(0, j - 1)]] += 1; i -= 1  # 多字
    return {lg: (err[lg], lab.count(lg)) for lg in err}

def cmd_report(a):
    """給文件用的總表：每種做法在混講帶上的整捲 CER，以及國語段、台語段各自的 CER"""
    meta = json.load(open(os.path.join(a.dir, "tapes.json")))
    R = lambda name, tape: os.path.join(a.dir, "runs", name, tape + ".json")
    rows = {}
    for tape, m in sorted(meta.items()):
        prim, alt = load_segments(R(a.primary, tape)), load_segments(R(a.taigi, tape))
        plans = [("Hearby 原本（只用 turbo）", lambda: list(prim)),
                 ("整場只用台語模型", lambda: list(alt)),
                 ("整場兩顆都跑＋時間窗", lambda: window_chosen(prim, alt, a.low, a.margin)),
                 ("理想分流（事先知道哪段是台語）", lambda: window_chosen(prim, alt, a.low, a.margin, m["spans"]))]
        if a.selective:
            sr = selective_results(a.dir, a.selective, tape, prim, a.low)[1]
            plans.append(("Hearby 版（不含漏聽判斷）", lambda: merge_spans(prim, sr, a.low, a.margin, skip_ratio=None)[0]))
            plans.append(("Hearby 版：只送沒把握的地方", lambda: merge_spans(prim, sr, a.low, a.margin)[0]))
        parts = [(s["lang"], ref_of(a.dir, s["id"], s["lang"])) for s in m["spans"]]
        for label, make in plans:
            chosen = make() or []
            txt = "".join(c[2] for c in sorted(chosen))
            r = rows.setdefault(label, {"tape": [], "zh": [0, 0], "nan": [0, 0]})
            r["tape"].append(cer(txt, m["ref"]))
            for lg, (e, n) in lang_errors(txt, parts).items(): r[lg][0] += e; r[lg][1] += n
    avg = lambda v: f"{100 * sum(v) / max(1, len(v)):.1f}%"
    pct = lambda en: f"{100 * en[0] / max(1, en[1]):.1f}%"
    print("| 做法 | 混講帶整捲 CER | 其中國語部分 | 其中台語部分 |\n|---|---|---|---|")
    for label, r in rows.items():
        print(f"| {label} | {avg(r['tape'])} | {pct(r['zh'])} | {pct(r['nan'])} |")

def route_acc(routed, spans):
    ok = tot = 0
    for f, t, who in routed:
        lg = lang_at(spans, (f + t) // 2)
        if lg is None: continue
        tot += t - f
        if (lg == "nan") == (who == "alt"): ok += t - f
    return ok / max(1, tot)

def cmd_hybrid(a):
    meta = json.load(open(os.path.join(a.dir, "tapes.json")))
    R = lambda name, tape: os.path.join(a.dir, "runs", name, tape + ".json")
    strategies = [("只用主模型", None), ("只用台語模型", None)]
    strategies += [(f"低信心換台語 θ={th}", ("switch", th)) for th in (-0.3, -0.4, -0.5, -0.6, -0.8)]
    strategies += [(f"兩邊比信心 +{m}", ("compare", m)) for m in (0.0, 0.1, 0.2, 0.3)]
    strategies += [(f"時間窗 主<{lo} 台語高{m}", ("window", lo, m)) for lo in (-0.2, -0.3, -0.4) for m in (0.0, 0.1, 0.2)]
    res = {s[0]: {"alt": [], "zh4": [], "route": []} for s in strategies}
    for tape, m in sorted(meta.items()):
        prim, alt = load_segments(R(a.primary, tape)), load_segments(R(a.taigi, tape))
        kind = "alt" if "_alt" in tape else "zh4"
        for label, spec in strategies:
            if label == "只用主模型": txt, routed = "".join(s[2] for s in prim), [(s[0], s[1], "prim") for s in prim]
            elif label == "只用台語模型": txt, routed = "".join(s[2] for s in alt), [(s[0], s[1], "alt") for s in alt]
            elif spec[0] == "switch": txt, routed = strategy_switch(prim, alt, spec[1])
            elif spec[0] == "window": txt, routed = strategy_window(prim, alt, spec[1], spec[2])
            else: txt, routed = strategy_compare(prim, alt, spec[1])
            res[label][kind].append(cer(txt, m["ref"]))
            res[label]["route"].append(route_acc(routed, m["spans"]))
    avg = lambda v: 100 * sum(v) / max(1, len(v))
    print("| 策略 | 華臺輪流帶 CER | 四華一臺帶 CER | 分流正確（時間比例） |\n|---|---|---|---|")
    for label, _ in strategies:
        r = res[label]
        print(f"| {label} | {avg(r['alt']):.1f}% | {avg(r['zh4']):.1f}% | {avg(r['route']):.0f}% |")
    if a.segments:   # 每段的信心與真實語言，看門檻要放哪
        for tape, m in sorted(meta.items()):
            for f, t, txt, lp, n in load_segments(R(a.primary, tape)):
                alp = [s[3] for s in overlap_text(load_segments(R(a.taigi, tape)), f, t)]
                print(f"{tape} {lang_at(m['spans'], (f + t) // 2)} {lp:6.2f} {(sum(alp) / len(alp)) if alp else 0:6.2f}  {txt[:30]}")


# ── selective：只把沒把握的地方送台語模型（Hearby 的做法）────────────────
# 台語模型（Breeze-ASR-26）不切時間戳：每 30 秒只吐一段字。所以不能拼成一檔再對回去——
# 每一截各存一個小檔，一次呼叫 whisper-cli（每個 -f 配一個 -of、模型只載入一次），每截的字各自對回那一截。
# 送的範圍＝主模型沒把握的段落＋有人聲但主模型沒出字的空檔（turbo 聽不懂台語時會整段跳過，實測一次跳 25 秒）。

VOICE_LEVEL = 0.015   # 跟 Hearby Transcriber.sliceSilence 同一條線

def levels(wav, f, t):
    """每 100 ms 的音量（跟 Hearby WavIO.blockLevels 同尺度：RMS×4，夾在 1）"""
    import array, math
    with wave.open(wav) as w:
        w.setpos(min(w.getnframes(), f * 16)); raw = w.readframes(max(0, t - f) * 16)
    x = array.array("h"); x.frombytes(raw[: len(raw) // 2 * 2])
    out = []
    for i in range(0, len(x), 1600):
        blk = x[i:i + 1600]
        out.append(min(1.0, math.sqrt(sum((v / 32768) ** 2 for v in blk) / len(blk)) * 4))
    return out

def voiced(wav, f, t):
    lv = levels(wav, f, t)
    return bool(lv) and sum(1 for v in lv if v > VOICE_LEVEL) >= 0.3 * len(lv)

def taigi_spans(prim, low, wav, total, pad=200, join=1500, min_len=1500, min_gap=2000):
    """主模型平均 log 機率 < low 的段落＋有人聲的空檔（≥ min_gap）→ 間隔 < join 的併起來 → 前後各墊 pad → 至少 min_len"""
    raw = [[f, t] for f, t, txt, lp, n in prim if lp < low]
    edges = [0] + [x for s in sorted(prim) for x in (s[0], s[1])] + [total]
    for i in range(0, len(edges) - 1, 2):
        g0, g1 = edges[i], edges[i + 1]
        if g1 - g0 >= min_gap and voiced(wav, g0, g1): raw.append([g0, g1])
    merged = []
    for f, t in sorted(raw):
        if merged and f - merged[-1][1] < join: merged[-1][1] = max(merged[-1][1], t)
        else: merged.append([f, t])
    out = []
    for f, t in merged:
        f, t = max(0, f - pad), min(total, t + pad)
        if t - f < min_len: c = (f + t) // 2; f, t = max(0, c - min_len // 2), min(total, c + min_len // 2)
        if out and f <= out[-1][1]: out[-1][1] = max(out[-1][1], t)
        else: out.append([f, t])
    return out

def punctuate(text):
    """台語模型用空格斷句、不加標點：中文字之間的空格換成「，」（跟其他行一樣好讀，CER 不受影響）。
    先拿掉單獨成句的「惜」「惜惜（喔）」——它在換氣、停頓處的幻聽（跟 Hearby Taigi.punctuate 一致）"""
    t = " ".join(w for w in text.split() if not re.fullmatch(r"惜+[喔哦啊]?", w))
    return re.sub(r"(?<=[一-鿿])\s+(?=[一-鿿])", "，", t)

def run_many(cli, model, wavs, bases, threads, extra=""):
    args = [cli, "-m", model, "-l", "zh", "-t", str(threads), "--prompt", PROMPT, "--carry-initial-prompt", "-ojf", "-np", *extra.split()]
    for w, b in zip(wavs, bases): args += ["-f", w, "-of", b]
    t0 = time.time(); subprocess.run(args, capture_output=True); return time.time() - t0

def chars(segs):
    return sum(len(norm(s[2])) for s in segs)

def merge_spans(prim, results, low, margin, fill_min=-0.5, skip_ratio=1.5):
    """每一截：主模型在截內（段落中點落在截裡）的段落 vs 台語模型這一截的字。
    換的條件（任一）：① 主模型沒把握、台語模型高出 margin；② 主模型這截沒字（跳過的空檔）、台語模型把握 > fill_min；
    ③ 主模型漏聽：台語模型的字數 ≥ 主模型的 skip_ratio 倍＋10 字、而且把握 > fill_min（turbo 的段落時間蓋到了，字卻只有一句）"""
    used, add = set(), []
    for (f, t), segs in results:
        if not segs: continue
        ps = [i for i, s in enumerate(prim) if f <= (s[0] + s[1]) // 2 < t]
        cp, ct = (wconf(prim, ps) if ps else None), wconf(segs, range(len(segs)))
        if ct is None: continue
        skipped = skip_ratio is not None and ct > fill_min and chars(segs) >= skip_ratio * chars([prim[i] for i in ps]) + 10
        if (cp is not None and cp < low and ct >= cp + margin) or (cp is None and ct > fill_min) or skipped:
            used.update(ps); add += segs
    chosen = [s for i, s in enumerate(prim) if i not in used] + add
    chosen.sort()
    routed = [(s[0], s[1], "alt" if s in add else "prim") for s in chosen]
    return chosen, routed

def selective_results(d, name, tape, prim, low):
    """重算這捲的截（純計算），讀每截的台語模型結果、時間對回原軸"""
    wav = os.path.join(d, "tapes", tape + ".wav"); total = wav_ms(wav)
    spans = taigi_spans(prim, low, wav, total)
    out = []
    for k, (f, t) in enumerate(spans):
        j = os.path.join(d, "runs", name, f"{tape}-{k:03d}.json")
        segs = [(max(f, f + s0), min(t, max(f + s1, f + s0 + 1)), punctuate(txt), lp, n)
                for s0, s1, txt, lp, n in load_segments(j)] if os.path.exists(j) else []
        out.append(((f, t), segs))
    return spans, out

def cmd_selective(a):
    meta = json.load(open(os.path.join(a.dir, "tapes.json")))
    work = os.path.join(a.dir, "runs", a.name); os.makedirs(work, exist_ok=True)
    rows, secs_sel, secs_full_audio, kept = [], 0, 0, []
    for tape, m in sorted(meta.items()):
        prim = load_segments(os.path.join(a.dir, "runs", a.primary, tape + ".json"))
        wav = os.path.join(a.dir, "tapes", tape + ".wav"); total = wav_ms(wav)
        spans, _ = selective_results(a.dir, a.name, tape, prim, a.low)
        bases = [os.path.join(work, f"{tape}-{k:03d}") for k in range(len(spans))]
        todo = [(sp, b) for sp, b in zip(spans, bases) if not os.path.exists(b + ".json")]
        tf = os.path.join(work, tape + ".secs")
        if todo:
            for (f, t), b in todo:
                with wave.open(wav) as w: w.setpos(f * 16); write_wav(b + ".wav", w.readframes((t - f) * 16))
            s = run_many(a.cli, a.model, [b + ".wav" for _, b in todo], [b for _, b in todo], a.threads, a.extra)
            open(tf, "w").write(str(s))
            for _, b in todo: os.rename(b + ".wav", b + ".wav.done")
        if os.path.exists(tf): secs_sel += float(open(tf).read())
        _, results = selective_results(a.dir, a.name, tape, prim, a.low)
        secs_full_audio += total / 1000
        sent = sum(t - f for f, t in spans) / total
        chosen, routed = merge_spans(prim, results, a.low, a.margin)
        txt = "".join(c[2] for c in chosen)
        kind = "alt" if "_alt" in tape else "zh4"
        rows.append((tape, kind, sent, cer(txt, m["ref"]), route_acc(routed, m["spans"])))
    avg = lambda v: 100 * sum(v) / max(1, len(v))
    for kind, label in (("alt", "華臺輪流帶"), ("zh4", "四華一臺帶")):
        r = [x for x in rows if x[1] == kind]
        print(f"| {label} | 送台語模型 {avg([x[2] for x in r]):.0f}% 的時間 | CER {avg([x[3] for x in r]):.1f}% | 分流正確 {avg([x[4] for x in r]):.0f}% |")
    print(f"台語模型實際耗時 {secs_sel:.0f}s（音檔共 {secs_full_audio:.0f}s）")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("prep"); p.add_argument("packs", nargs="+"); p.add_argument("--out", required=True)
    p = sp.add_parser("run"); p.add_argument("dir"); p.add_argument("name"); p.add_argument("model")
    p.add_argument("--cli", default="whisper-cli"); p.add_argument("--threads", type=int, default=8); p.add_argument("--force", action="store_true")
    p.add_argument("--extra", default="", help="多給 whisper-cli 的參數，例：'-bs 1 -bo 1'")
    p = sp.add_parser("selective"); p.add_argument("dir"); p.add_argument("name"); p.add_argument("primary"); p.add_argument("model")
    p.add_argument("--cli", default="whisper-cli"); p.add_argument("--threads", type=int, default=8); p.add_argument("--extra", default="")
    p.add_argument("--low", type=float, default=-0.3); p.add_argument("--margin", type=float, default=0.2)
    p = sp.add_parser("report"); p.add_argument("dir"); p.add_argument("primary"); p.add_argument("taigi")
    p.add_argument("--selective", help="selective 跑出來的那組名字"); p.add_argument("--low", type=float, default=-0.3); p.add_argument("--margin", type=float, default=0.2)
    p = sp.add_parser("drafts"); p.add_argument("dir"); p.add_argument("name")
    p = sp.add_parser("mix"); p.add_argument("dir")
    p = sp.add_parser("score"); p.add_argument("dir"); p.add_argument("names", nargs="+"); p.add_argument("--detail", action="store_true")
    p = sp.add_parser("hybrid"); p.add_argument("dir"); p.add_argument("primary"); p.add_argument("taigi"); p.add_argument("--segments", action="store_true")
    a = ap.parse_args()
    {"prep": cmd_prep, "run": cmd_run, "drafts": cmd_drafts, "mix": cmd_mix, "score": cmd_score, "hybrid": cmd_hybrid,
     "selective": cmd_selective, "report": cmd_report}[a.cmd](a)

if __name__ == "__main__":
    main()
