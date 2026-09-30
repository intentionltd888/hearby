// ContractTests — every case in contract/fixtures (answers produced by the macOS core) must come out the same here.
using System.Text.Json.Nodes;
using Hearby.Core;
using static Hearby.Core.Tests.Fixture;

namespace Hearby.Core.Tests;

public class ContractTests
{
    [Fact]
    public void CleanPunct()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("clean_punct")) Assert.Equal(S(c!["expected"]), Clean.NormalizePunct(S(c["input"])));
    }

    [Fact]
    public void HallucinationFilter()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("hallucination"))
        {
            var text = S(c!["text"]);
            var got = Hallucination.IsJunk(text, new Hallucination.Signals(null, IN(c["durationMs"])));
            Assert.True(B(c["expected"]) == got, $"isJunk({text}) expected {B(c["expected"])}");
        }
    }

    [Fact]
    public void MergedForLLM()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("merged_for_llm")) Assert.Equal(S(c!["expected"]), Transcriber.MergedForLLM(S(c["input"])));
    }

    [Fact]
    public void WhisperJson()
    {
        using var sb = new Sandbox();
        int k = 0;
        foreach (var c in Cases("whisper_json"))
        {
            var f = Path.Combine(sb.Box, $"w{k++}.json");
            File.WriteAllText(f, S(c!["json"]));
            var r = Transcriber.ParseWhisperJson(f, I(c["offsetMs"]), S(c["who"]));
            var segs = c["segs"]!.AsArray();
            Assert.Equal(segs.Count, r.Segs.Count);
            for (int i = 0; i < segs.Count; i++)
            {
                Assert.Equal(I(segs[i]!["fromMs"]), r.Segs[i].FromMs);
                Assert.Equal(I(segs[i]!["toMs"]), r.Segs[i].ToMs);
                Assert.Equal(S(segs[i]!["text"]), r.Segs[i].Text);
                Assert.Equal(S(segs[i]!["who"]), r.Segs[i].Who);
            }
            Assert.Equal(Pairs(c["loops"]), r.Loops);
            Assert.Equal(D(c["rawRepeat"]), r.RawRepeat, 12);
        }
    }

    [Fact]
    public void Degeneracy()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("degeneracy"))
        {
            var texts = SL(c!["texts"]);
            var segs = texts.Select((t, i) => new Segment(i * 1000, i * 1000 + 900, t, "我方")).ToList();
            var r = Transcriber.Degeneracy(segs, D(c["rawRepeatRatio"]));
            Assert.Equal(B(c["bad"]), r.Bad);
            Assert.Equal(D(c["score"]), r.Score, 9);
        }
    }

    [Fact]
    public void Slices()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("slices"))
        {
            if (S(c!["kind"]) == "split")
            {
                var got = Transcriber.Split(Pairs(c["slices"]), c["cuts"]!.AsArray().Select(x => I(x)).ToList(), I(c["minMs"]));
                Assert.Equal(Pairs(c["expected"]), got);
            }
            else
            {
                var wav = Path.Combine(sb.Box, Guid.NewGuid().ToString("N") + ".wav");
                WavIO.WritePcmFile(wav, Sandbox.Synth(c["spec"]!.AsArray()));
                Assert.Equal(I(c["totalMs"]), WavIO.DurationMs(wav));
                Assert.Equal(Pairs(c["expected"]), Transcriber.SilenceSlices(wav, I(c["totalMs"]), I(c["targetMs"])));
            }
        }
    }

    [Fact]
    public void QuietBoost()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("quiet_boost"))
        {
            var pcm = S(c!["kind"]) == "bursty" ? Sandbox.Bursty(I(c["amp"])) : Sandbox.Synth(new JsonArray(new JsonArray(10, I(c["amp"]))));
            var lv = WavIO.BlockLevels(pcm);
            Assert.Equal(D(c["peakLevel"]), lv.Max(), 6);
            var g = Transcriber.QuietBoost(lv, pcm);
            if (c["expected"] is null) Assert.Null(g);
            else { Assert.NotNull(g); Assert.Equal(D(c["expected"]), g!.Value, 2); }
        }
    }

    static PauseSpan Span(JsonNode? n) => new(D(n!["atSeconds"]), DateTimeOffset.Parse(S(n["began"])), n["ended"] is null ? null : DateTimeOffset.Parse(S(n["ended"])));

    [Fact]
    public void Pause()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("pause"))
        {
            switch (S(c!["kind"]))
            {
                case "durText": Assert.Equal(S(c["expected"]), PauseSpan.DurText(D(c["seconds"]))); break;
                case "markerLine":
                    var sp = Span(c["span"]);
                    Assert.Equal(I(c["atMs"]), sp.AtMs);
                    Assert.Equal(S(c["expected"]), sp.MarkerLine);
                    break;
                case "weave":
                {
                    var pauses = c["pauses"]!.AsArray().Select(Span).ToList();
                    var lines = c["lines"]!.AsArray().Select(l => (I(l!["fromMs"]), S(l["text"]))).ToList();
                    var total = D(c["totalSeconds"]);
                    Assert.Equal(SL(c["expected"]), PauseSpan.Weave(lines, pauses, total));
                    Assert.Equal(SN(c["note"]), PauseSpan.Note(pauses, total));
                    var mid = PauseSpan.MidPauses(pauses, total);
                    var want = c["mid"]!.AsArray();
                    Assert.Equal(want.Count, mid.Count);
                    for (int i = 0; i < mid.Count; i++) Assert.Equal(D(want[i]!["atSeconds"]), mid[i].AtSeconds);
                    break;
                }
                case "clock":
                {
                    var t0 = DateTimeOffset.Parse(S(c["startedAt"]));
                    var clock = new RecordingClock(t0);
                    foreach (var st in c["steps"]!.AsArray())
                    {
                        var now = t0.AddSeconds(D(st!["t"]));
                        object? ret = null;
                        switch (S(st["event"]))
                        {
                            case "pause": ret = clock.Pause(now); break;
                            case "resume": ret = clock.Resume(now); break;
                            case "sleep": ret = clock.NoteSleep(now); break;
                            case "wake": ret = clock.NoteWake(now); break;
                            case "close": clock.Close(now); break;
                        }
                        if (st["ret"] is JsonValue rv) Assert.Equal(rv.GetValue<bool>(), (bool)ret!);
                        Assert.Equal(D(st["recorded"]), clock.Recorded(now), 6);
                        Assert.Equal(B(st["isPaused"]), clock.IsPaused);
                        Assert.Equal(D(st["currentPause"]), clock.CurrentPause(now), 6);
                        Assert.Equal(B(st["slept"]), clock.SleptWhileRecording);
                    }
                    Assert.Equal(D(c["sleepSeconds"]), clock.SleepSeconds, 6);
                    Assert.Equal(D(c["pausedSeconds"]), clock.PausedSeconds, 6);
                    Assert.Equal(c["pauses"]!.AsArray().Count, clock.Pauses.Count);
                    break;
                }
            }
        }
    }

    static MeetingScenario? Scn(JsonNode? n) => n is null ? null : MeetingScenarioExt.FromRaw(S(n));

    [Fact]
    public void PolishGuardsAll()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("polish_guards"))
        {
            var fn = S(c!["fn"]);
            switch (fn)
            {
                case "sanitizeModelOutput": Assert.Equal(SN(c["expected"]), PolishGuards.SanitizeModelOutput(S(c["input"]))); break;
                case "verifyCitations":
                    var (md, n) = PolishGuards.VerifyCitations(S(c["input"]), S(c["transcript"]));
                    Assert.Equal(S(c["expected"]), md); Assert.Equal(I(c["removed"]), n); break;
                case "applyMechanicalCorrections":
                    var (t, sem) = PolishGuards.ApplyMechanicalCorrections(S(c["transcript"]), S(c["corrections"]));
                    Assert.Equal(S(c["expected"]), t); Assert.Equal(S(c["semantic"]), sem); break;
                case "filterAttendees": Assert.Equal(S(c["expected"]), PolishGuards.FilterAttendees(S(c["input"]), S(c["attendees"]))); break;
                case "sanitizeTodoOwners": Assert.Equal(S(c["expected"]), PolishGuards.SanitizeTodoOwners(S(c["input"]), S(c["attendees"]))); break;
                case "stripExampleTodos": Assert.Equal(S(c["expected"]), PolishGuards.StripExampleTodos(S(c["input"]))); break;
                case "normalizeEmptyMarkers": Assert.Equal(S(c["expected"]), PolishGuards.NormalizeEmptyMarkers(S(c["input"]))); break;
                case "tidyTodoRendering": Assert.Equal(S(c["expected"]), PolishGuards.TidyTodoRendering(S(c["input"]))); break;
                case "stripExampleNames": Assert.Equal(S(c["expected"]), PolishGuards.StripExampleNames(S(c["input"]))); break;
                case "clearPlaceholderOwners": Assert.Equal(S(c["expected"]), PolishGuards.ClearPlaceholderOwners(S(c["input"]))); break;
                case "insertOnsiteNote": Assert.Equal(S(c["expected"]), PolishGuards.InsertOnsiteNote(S(c["input"]), Scn(c["scenario"]), IN(c["onsiteCount"]))); break;
                case "sanitizeTodoDues": Assert.Equal(S(c["expected"]), PolishGuards.SanitizeTodoDues(S(c["input"]), S(c["source"]))); break;
                case "normalizeBriefLedger": Assert.Equal(S(c["expected"]), Hearby.Core.Polish.NormalizeBriefLedger(S(c["input"]), SL(c["brief"]))); break;
                default: throw new Exception("unknown fn " + fn);
            }
        }
    }

    [Fact]
    public void BuildNotes()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("build_notes"))
        {
            var name = S(c!["name"]);
            var glossaryFile = Path.Combine(Paths.Support, "glossary.txt");
            if (SN(c["glossary"]) is { } g) File.WriteAllText(glossaryFile, g); else if (File.Exists(glossaryFile)) File.Delete(glossaryFile);
            ConfigStore.Shared.Update(x => x.EndpointModel = SN(c["endpointModel"]));
            var input = new Hearby.Core.Polish.Input(S(c["transcript"]), S(c["title"]), S(c["attendees"]), S(c["dateStr"]), S(c["durStr"]), SL(c["warnings"]), S(c["audioLine"]))
            {
                Scene = RecordSceneExt.FromRaw(S(c["scene"]))!.Value, Scenario = Scn(c["scenario"]), Onsite = B(c["onsite"]), OnsiteCount = IN(c["onsiteCount"]),
                Brief = SL(c["brief"]), PauseNote = SN(c["pauseNote"]), Links = SL(c["links"]), Corrections = SN(c["corrections"]),
                Baseline = SN(c["baseline"]), History = SL(c["history"]), Context = Ctx(c["context"]),
            };
            var pid = SN(c["providerID"]);
            FakeProvider? fake = pid is null or "none" ? null : new FakeProvider(pid, SN(c["reply"]), SN(c["err"]));
            IProvider? provider = pid == "none" ? new NoneProvider() : fake;
            var r = Hearby.Core.Polish.BuildNotes(input, provider);
            Assert.True(S(c["md"]) == r.Md, $"[{name}] md differs\n--- want\n{S(c["md"])}\n--- got\n{r.Md}");
            Assert.Equal(S(c["summary"]), r.Summary);
            Assert.Equal(SN(c["polishErr"]), r.PolishErr);
            Assert.True(SN(c["seenSystem"]) == fake?.SeenSystem, $"[{name}] system prompt differs\n--- want\n{SN(c["seenSystem"])}\n--- got\n{fake?.SeenSystem}");
            Assert.True(SN(c["seenUser"]) == fake?.SeenUser, $"[{name}] user message differs\n--- want\n{SN(c["seenUser"])}\n--- got\n{fake?.SeenUser}");
            Assert.Equal(SL(c["threeLines"]), Hearby.Core.Polish.ThreeLines(r.Md));
        }
        ConfigStore.Shared.Update(x => x.EndpointModel = null);
    }

    static PolishContext? Ctx(JsonNode? n) => n is null ? null : new PolishContext(S(n["roster"]), SL(n["decided"]), SL(n["openTodos"]), SL(n["names"]))
    {
        Projects = n["projects"] is { } p ? SL(p) : [], Undecided = n["undecided"] is { } u ? SL(u) : [],
    };
    static NameFixes.Fix Fx(JsonNode? n) => new(S(n!["heard"]), S(n["name"]), B(n["sure"]), SL(n["stamps"]));
    static string FixText(NameFixes.Fix f) => $"{f.Heard}→{f.Name}|{f.Sure}|{string.Join(",", f.Stamps)}";
    static string CtxText(PolishContext? c) => c is null ? "null" : $"{c.Roster}\n#D {string.Join("¶", c.Decided)}\n#O {string.Join("¶", c.OpenTodos)}\n#N {string.Join("¶", c.Names)}\n#P {string.Join("¶", c.Projects)}\n#U {string.Join("¶", c.Undecided)}";

    sealed class StubConverter : IChineseConverter { public string ToTraditional(string s) => s.Replace("涂", "塗").Replace("说", "說"); }

    [Fact]
    public void RosterNamesSurviveConversion()
    {
        // not a fixture (the macOS side uses ICU, the tests here have no converter): the surname 涂 must not become 塗 for roster names
        var saved = Clean.Converter;
        try
        {
            Clean.Converter = new StubConverter();
            Assert.Equal("塗小明說", Clean.ToTraditional("涂小明说"));
            Assert.Equal("涂小明說，塗改液", Clean.ToTraditional("涂小明说，涂改液", ["涂小明", "林小安"]));
            Assert.Equal(Clean.ToTraditional("涂说"), Clean.ToTraditional("涂说", []));
        }
        finally { Clean.Converter = saved; }
    }

    [Fact]
    public void SoundAlikeAll()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("sound_alike"))
        {
            switch (S(c!["fn"]))
            {
                case "table":
                    // A checkout with CRLF line endings must still hash the same table
                    var table = PinyinData.Table.Replace("\r", "");
                    Assert.Equal(S(c["sha256"]), Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(table))));
                    Assert.Equal(I(c["chars"]), Pinyin.Count);
                    break;
                case "of":
                    Assert.Equal(c["expected"]!.AsArray().Select(SN).ToList(), SL(c["chars"]).Select(Pinyin.Of).ToList());
                    break;
                case "fromZhuyin":
                    Assert.Equal(c["expected"]!.AsArray().Select(SN).ToList(), SL(c["input"]).Select(Pinyin.FromZhuyin).ToList());
                    break;
                case "key":
                    Assert.Equal(SL(c["expected"]), SL(c["input"]).Select(Pinyin.Key).ToList());
                    break;
                case "coarse":
                    Assert.Equal(SL(c["expected"]), SL(c["input"]).Select(Pinyin.Coarse).ToList());
                    break;
                case "targets":
                {
                    var (t, h) = SoundAlike.Targets(S(c["roster"]));
                    Assert.Equal(c["targets"]!.AsArray().Select(x => S(x!["name"]) + "|" + string.Join(" ", SL(x["syllables"])) + "|" + I(x["rank"])).ToList(),
                        t.Select(x => x.Name + "|" + string.Join(" ", x.Syllables) + "|" + x.Rank).ToList());
                    Assert.Equal(SL(c["heard"]), h);
                    break;
                }
                case "scan":
                {
                    var (t, h) = SoundAlike.Targets(S(c["roster"]));
                    var hits = SoundAlike.Scan(S(c["transcript"]), t, h);
                    Assert.Equal(c["expected"]!.AsArray().Select(x => HitText(ToHit(x))).ToList(), hits.Select(HitText).ToList());
                    Assert.Equal(SL(c["lines"]), SoundAlike.Lines(hits));
                    break;
                }
                case "lines":
                    Assert.Equal(SL(c["expected"]), SoundAlike.Lines(c["hits"]!.AsArray().Select(ToHit).ToList()));
                    break;
                case "close":
                    Assert.Equal(c["expected"]!.AsArray().Select(B).ToList(), c["pairs"]!.AsArray().Select(p => SoundAlike.Close(S(p![0]), S(p[1]))).ToList());
                    break;
                default:
                    throw new Exception("sound_alike: unknown fn " + S(c["fn"]));
            }
        }
    }

    static SoundAlike.Hit ToHit(JsonNode? x) =>
        new() { Heard = S(x!["heard"]), Names = SL(x["names"]), Count = I(x["count"]), Stamps = SL(x["stamps"]), Rank = I(x["rank"]) };
    static string HitText(SoundAlike.Hit h) => $"{h.Heard}|{string.Join("／", h.Names)}|{h.Count}|{string.Join(" ", h.Stamps)}|{h.Rank}";

    [Fact]
    public void NameFixesAll()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("name_fixes"))
        {
            var fn = S(c!["fn"]);
            switch (fn)
            {
                case "make":
                    Assert.Equal(CtxText(Ctx(c["expected"])), CtxText(PolishContext.Make(S(c["roster"]), SN(c["threads"]), SN(c["open"]), SN(c["excluding"]), I(c["limit"]))));
                    break;
                case "parse":
                    Assert.Equal(c["expected"] is null ? "null" : FixText(Fx(c["expected"])), NameFixes.Parse(S(c["line"])) is { } f ? FixText(f) : "null");
                    break;
                case "extract":
                {
                    var (notes, fixes) = NameFixes.Extract(S(c["notes"]));
                    Assert.Equal(S(c["expected"]), notes);
                    Assert.Equal(c["fixes"]!.AsArray().Select(x => FixText(Fx(x))).ToList(), fixes.Select(FixText).ToList());
                    break;
                }
                case "apply":
                {
                    var r = NameFixes.Apply(c["fixes"]!.AsArray().Select(Fx).ToList(), S(c["transcript"]), SL(c["names"]));
                    Assert.Equal(S(c["expected"]), r.Transcript);
                    Assert.Equal(c["applied"]!.AsArray().Select(x => FixText(Fx(x!["fix"])) + "=" + I(x["count"])).ToList(), r.Applied.Select(a => FixText(a.Fix) + "=" + a.Count).ToList());
                    Assert.Equal(c["skipped"]!.AsArray().Select(x => FixText(Fx(x))).ToList(), r.Skipped.Select(FixText).ToList());
                    break;
                }
                case "markUnsure":
                    Assert.Equal(S(c["expected"]), NameFixes.MarkUnsure(S(c["notes"]), c["fixes"]!.AsArray().Select(Fx).ToList(), SN(c["transcript"]) ?? ""));
                    break;
                case "headerLine":
                    Assert.Equal(SN(c["expected"]), NameFixes.HeaderLine(c["applied"]!.AsArray().Select(x => (Fx(x!["fix"]), I(x["count"]))).ToList(), c["unsure"]!.AsArray().Select(Fx).ToList()));
                    break;
                case "dropRepeatedTodos":
                    Assert.Equal(S(c["expected"]), NameFixes.DropRepeatedTodos(S(c["notes"]), SL(c["open"])));
                    break;
                case "memoryBlock":
                    Assert.Equal(S(c["expected"]), Prompt.MemoryBlock(Ctx(c["context"])!));
                    break;
                default:
                    Assert.Fail("unknown fn " + fn);
                    break;
            }
        }
    }

    static (List<NameLedger.Entry>, List<NameLedger.Question>) Ledger(JsonNode? n) => (
        n!["entries"]!.AsArray().Select(x => new NameLedger.Entry(S(x!["heard"]), S(x["name"]), S(x["how"]), S(x["who"]), S(x["date"]), S(x["meeting"]))).ToList(),
        n["questions"]!.AsArray().Select(x => new NameLedger.Question(S(x!["heard"]), S(x["name"]), S(x["meeting"]), S(x["answer"]))).ToList());
    static string LedgerText((List<NameLedger.Entry> E, List<NameLedger.Question> Q) r) =>
        string.Join("\n", r.E.Select(e => $"{e.Heard}|{e.Name}|{e.How}|{e.Who}|{e.Date}|{e.Meeting}")) + "\n#Q " +
        string.Join("\n", r.Q.Select(q => $"{q.Heard}|{q.Name}|{q.Meeting}|{q.Answer}|{q.Yes}|{q.No}"));
    static List<string> PairTexts(IEnumerable<(string, string)> ps) => ps.Select(p => p.Item1 + "→" + p.Item2).ToList();
    static List<string> PairTexts(JsonNode? n) => n!.AsArray().Select(x => S(x![0]) + "→" + S(x[1])).ToList();

    [Fact]
    public void NameLedgerAll()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("name_ledger"))
        {
            var fn = S(c!["fn"]);
            switch (fn)
            {
                case "parse":
                {
                    var r = NameLedger.Parse(S(c["text"]));
                    Assert.Equal(LedgerText(Ledger(c["expected"])), LedgerText((r.Entries, r.Questions)));
                    foreach (var (q, j) in r.Questions.Zip(c["expected"]!["questions"]!.AsArray()))
                    { Assert.Equal(B(j!["yes"]), q.Yes); Assert.Equal(B(j["no"]), q.No); }
                    break;
                }
                case "adding":
                {
                    var (e, _) = Ledger(new JsonObject { ["entries"] = c["entries"]!.DeepClone(), ["questions"] = new JsonArray() });
                    var (_, q) = Ledger(new JsonObject { ["entries"] = new JsonArray(), ["questions"] = c["questions"]!.DeepClone() });
                    Assert.Equal(S(c["expected"]), NameLedger.Adding(e, q, SN(c["text"])));
                    break;
                }
                case "answering":
                    Assert.Equal(S(c["expected"]), NameLedger.Answering(S(c["heard"]), S(c["name"]), S(c["answer"]), S(c["text"])));
                    break;
                case "contextLines":
                {
                    var r = NameLedger.Parse(S(c["text"]));
                    Assert.Equal(SL(c["expected"]), NameLedger.ContextLines(r.Entries, r.Questions));
                    Assert.Equal(PairTexts(c["aliasPairs"]), PairTexts(NameLedger.AliasPairs(r.Entries).Select(p => (p.Alias, p.Canonical))));
                    break;
                }
                case "classify":
                {
                    var others = c["others"]!.AsArray().Select(x => (S(x!["id"]), S(x["transcript"]))).ToList();
                    Assert.Equal(S(c["expected"]), NameLedger.Classify(S(c["heard"]), S(c["meeting"]), others, SL(c["known"])));
                    break;
                }
                case "pairsFromCorrections":
                    Assert.Equal(PairTexts(c["expected"]), PairTexts(NameLedger.PairsFromCorrections(S(c["corrections"]), SL(c["known"]))));
                    break;
                case "pairsFromEdit":
                    Assert.Equal(PairTexts(c["expected"]), PairTexts(NameLedger.PairsFromEdit(S(c["old"]), S(c["new"]), SL(c["known"]))));
                    break;
                case "hunks":
                {
                    var want = c["expected"]!.AsArray().Select(x => S(x!["old"]) + "→" + S(x["new"]) + " [" + string.Join(",", x["alts"]!.AsArray().Select(y => S(y![0]) + "→" + S(y[1]))) + "]").ToList();
                    var got = NameLedger.Hunks(S(c["x"]), S(c["y"]), SL(c["known"])).Select(h => h.Old + "→" + h.New + " [" + string.Join(",", h.Alts.Select(y => y.Item1 + "→" + y.Item2)) + "]").ToList();
                    Assert.Equal(want, got);
                    break;
                }
                case "align":
                {
                    var want = c["expected"]!.AsArray().Select(x => (IN(x![0]), IN(x[1]))).ToList();
                    Assert.Equal(want, NameLedger.Align(Str.Chars(S(c["x"])), Str.Chars(S(c["y"]))).Select(p => (p.A, p.B)).ToList());
                    break;
                }
                case "questionsFromRecord":
                {
                    var want = c["expected"]!.AsArray().Select(x => S(x!["heard"]) + "→" + S(x["name"]) + "|" + S(x["meeting"])).ToList();
                    Assert.Equal(want, NameLedger.QuestionsFromRecord(S(c["md"]), S(c["meeting"])).Select(q => q.Heard + "→" + q.Name + "|" + q.Meeting).ToList());
                    break;
                }
                case "makeWithNames":
                    Assert.Equal(CtxText(Ctx(c["expected"])), CtxText(PolishContext.Make(S(c["roster"]), null, null, null, I(c["limit"]), S(c["names"]))));
                    break;
                case "followPrune":
                    Assert.Equal(S(c["expected"]), FollowUps.Prune(S(c["notes"])));
                    break;
                case "followDone":
                    Assert.Equal(SL(c["expected"]), FollowUps.DoneItems(S(c["md"])));
                    break;
                case "followTick":
                    Assert.Equal(S(c["expected"]), FollowUps.Tick(S(c["open"]), SL(c["done"]), S(c["meeting"])));
                    break;
                case "makeWithState":
                {
                    var got = PolishContext.Make(S(c["roster"]), S(c["threads"]), S(c["open"]), null, I(c["limit"]), null, S(c["state"]));
                    Assert.Equal(CtxText(Ctx(c["expected"])), CtxText(got));
                    Assert.Equal(SN(c["memoryBlock"]), got is null ? null : Prompt.MemoryBlock(got));
                    break;
                }
                default:
                    Assert.Fail("unknown fn " + fn);
                    break;
            }
        }
    }

    [Fact]
    public void RecordMd()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("record_md"))
        {
            var name = S(c!["name"]);
            if (name == "todoParts")
            {
                var t = RecordMD.TodoParts(S(c["raw"]));
                Assert.Equal((S(c["item"]), S(c["owner"]), S(c["due"])), (t.Item, t.Owner, t.Due));
                continue;
            }
            if (name == "sceneFromTitle") { Assert.Equal(S(c["scene"]), RecordSceneExt.FromMdTitle(S(c["raw"])).Raw()); continue; }
            var md = S(c["md"]);
            var r = RecordMD.Parse(md);
            Assert.Equal(S(c["title"]), r.Title);
            Assert.Equal(S(c["meta"]), r.Meta);
            Assert.Equal(S(c["declaredAttendees"]), r.DeclaredAttendees);
            var secs = c["sections"]!.AsArray();
            Assert.Equal(secs.Count, r.Sections.Count);
            for (int i = 0; i < secs.Count; i++) { Assert.Equal(S(secs[i]!["name"]), r.Sections[i].Name); Assert.Equal(SL(secs[i]!["lines"]), r.Sections[i].Lines); }
            var todos = c["todos"]!.AsArray();
            Assert.Equal(todos.Count, r.Todos.Count);
            for (int i = 0; i < todos.Count; i++)
                Assert.Equal(new Todo(S(todos[i]!["item"]), S(todos[i]!["owner"]), S(todos[i]!["due"]), B(todos[i]!["done"])), r.Todos[i]);
            Assert.Equal(SL(c["images"]), r.Images);
            var p = r.Parts;
            Assert.Equal((S(c["parts"]!["date"]), S(c["parts"]!["dur"]), S(c["parts"]!["custom"])), (p.Date, p.Dur, p.Custom));
            Assert.Equal(S(c["summaryText"]), r.SummaryText);
            Assert.Equal(SL(c["people"]), r.People);
            Assert.Equal(S(c["scene"]), r.Scene.Raw());
            Assert.Equal(S(c["clientVersion"]), RecordMD.ClientVersion(md));
            Assert.Equal(SN(c["transcript"]), RecordMD.Transcript(md));
            Assert.Equal(SL(c["threeLines"]), Hearby.Core.Polish.ThreeLines(md));
        }
    }

    [Fact]
    public void RepolishParts()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("repolish_parts"))
        {
            if (S(c!["fn"]) == "realAttendees") Assert.Equal(SL(c["expected"]), Repolish.RealAttendees(SL(c["people"])));
            else
            {
                var old = c["oldTodos"]!.AsArray().Select(t => new Todo(S(t!["item"]), S(t["owner"]), S(t["due"]), B(t["done"]))).ToList();
                Assert.Equal(S(c["expected"]), Repolish.RestoreTodoChecks(S(c["md"]), old));
            }
        }
    }

    [Fact]
    public void Memory()
    {
        using var sb = new Sandbox();
        var c = Cases("memory")[0]!;
        ConfigStore.Shared.Update(x => x.MemoryEnabled = true);
        MemoryStore.Ensure();
        foreach (var kv in c["seeded"]!.AsObject()) File.WriteAllText(Path.Combine(Paths.Memory, kv.Key), S(kv.Value));
        foreach (var st in c["steps"]!.AsArray())
        {
            var id = S(st!["id"]);
            var dir = Path.Combine(Paths.Meetings, id);
            Directory.CreateDirectory(dir);
            var md = Path.Combine(dir, id + ".md");
            File.WriteAllText(md, S(st["md"]));
            MemoryStore.Sync(md);
            foreach (var kv in st["files"]!.AsObject())
                Assert.True(S(kv.Value) == File.ReadAllText(Path.Combine(Paths.Memory, kv.Key)), $"step {I(st["step"])} {kv.Key}\n--- want\n{S(kv.Value)}\n--- got\n{File.ReadAllText(Path.Combine(Paths.Memory, kv.Key))}");
            var idx = JsonNode.Parse(File.ReadAllText(Path.Combine(Paths.Memory, "index.json")));
            Assert.True(JsonNode.DeepEquals(Norm(st["index"]), Norm(idx)), $"index.json step {I(st["step"])}\n--- want\n{st["index"]}\n--- got\n{idx}");
        }
        Assert.Equal(SL(c["openItems"]), MemoryStore.OpenItems());
        foreach (var kv in c["parseDur"]!.AsObject()) Assert.Equal(D(kv.Value), MemoryStore.ParseDur(kv.Key));
    }

    [Fact]
    public void AliasTable()
    {
        using var sb = new Sandbox();
        MemoryStore.Ensure();
        foreach (var c in Cases("alias_table"))
        {
            File.WriteAllText(Path.Combine(Paths.Memory, "PEOPLE.md"), S(c!["people"]));
            File.WriteAllText(Path.Combine(Paths.Memory, "GLOSSARY.md"), S(c["glossary"]));
            var table = Clean.AliasTable();
            Assert.Equal(c["expected"]!.AsArray().Select(x => (S(x![0]), S(x[1]))).ToList(), table.Select(x => (x.Alias, x.Canonical)).ToList());
            var (applied, n) = Clean.ApplyAliases(S(c["text"]), table);
            Assert.Equal(S(c["applied"]), applied);
            Assert.Equal(I(c["count"]), n);
        }
    }

    /// Replays the steps in order: write a file (relative to HEARBY_OUTPUT_ROOT, optional modification time), sync one meeting,
    /// sync every meeting, forget a meeting in .hearby-written.json; after each sync the memory files, index, book and backups must match
    [Fact]
    public void MemorySync()
    {
        using var sb = new Sandbox();
        ConfigStore.Shared.Update(x => x.MemoryEnabled = true);
        MemoryStore.Ensure();
        var day = new MemoryStore.Backups().Day;
        foreach (var st in Cases("memory_sync"))
        {
            switch (S(st!["op"]))
            {
                case "write":
                {
                    var path = Path.Combine(Paths.Root, S(st["path"]));
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    File.WriteAllText(path, S(st["text"]));
                    if (SN(st["modified"]) is { } m) File.SetLastWriteTimeUtc(path, DateTimeOffset.Parse(m).UtcDateTime);
                    break;
                }
                case "forget":
                {
                    var bookPath = Path.Combine(Paths.Memory, MemoryStore.WrittenBook);
                    var book = JsonNode.Parse(File.ReadAllText(bookPath))!.AsObject();
                    book["meetings"]!.AsObject().Remove(S(st["id"]));
                    File.WriteAllText(bookPath, book.ToJsonString());
                    break;
                }
                case "sync":
                {
                    var r = MemoryStore.Sync(Path.Combine(Paths.Root, S(st["path"])));
                    CheckReport(st["report"], r, day, S(st["path"]));
                    CheckMemory(st["after"]!, day, S(st["path"]));
                    break;
                }
                case "syncAll":
                {
                    var rs = MemoryStore.Sync(MemoryStore.AllRecords());
                    var want = st["reports"]!.AsArray();
                    Assert.Equal(want.Count, rs.Count);
                    for (int i = 0; i < rs.Count; i++)
                    {
                        Assert.Equal(S(want[i]!["path"]), "會議/" + Path.GetFileName(Path.GetDirectoryName(rs[i].Path)) + "/" + Path.GetFileName(rs[i].Path));
                        Assert.Equal(SN(want[i]!["error"]), rs[i].Error);
                        CheckReport(want[i]!["report"], rs[i].Report, day, S(want[i]!["path"]));
                    }
                    CheckMemory(st["after"]!, day, "syncAll");
                    break;
                }
                default: throw new Exception("unknown op " + S(st["op"]));
            }
        }
    }

    static void CheckReport(JsonNode? want, MemoryStore.SyncReport? r, string day, string label)
    {
        if (want is null) { Assert.Null(r); return; }
        Assert.NotNull(r);
        Assert.Equal(S(want["id"]), r!.Id);
        Assert.True(B(want["isNew"]) == r.IsNew, $"[{label}] isNew");
        Assert.Equal(SL(want["changed"]), r.Changed);
        Assert.True(I(want["kept"]) == r.Kept, $"[{label}] kept: want {I(want["kept"])} got {r.Kept}");
        Assert.Equal(SL(want["backups"]), r.Backups.Select(b => Path.GetFileName(b).Replace(day, "{DAY}")).ToList());
    }

    static void CheckMemory(JsonNode after, string day, string label)
    {
        foreach (var kv in after["files"]!.AsObject())
        {
            var got = File.ReadAllText(Path.Combine(Paths.Memory, kv.Key));
            Assert.True(S(kv.Value) == got, $"[{label}] {kv.Key}\n--- want\n{S(kv.Value)}\n--- got\n{got}");
        }
        foreach (var (f, key) in new[] { ("index.json", "index"), (MemoryStore.WrittenBook, "written") })
        {
            var got = JsonNode.Parse(File.ReadAllText(Path.Combine(Paths.Memory, f)));
            Assert.True(JsonNode.DeepEquals(Norm(after[key]), Norm(got)), $"[{label}] {f}\n--- want\n{after[key]}\n--- got\n{got}");
        }
        var baks = Directory.EnumerateFiles(Paths.Memory).Select(x => Path.GetFileName(x)).Where(n => n.Contains(".bak-")).ToList();
        var wantBaks = after["backups"]!.AsObject();
        Assert.Equal(wantBaks.Select(kv => kv.Key).Order(StringComparer.Ordinal), baks.Select(n => n.Replace(day, "{DAY}")).Order(StringComparer.Ordinal));
        foreach (var n in baks)
        {
            var got = File.ReadAllText(Path.Combine(Paths.Memory, n));
            var want = S(wantBaks[n.Replace(day, "{DAY}")]);
            // index.json backups are copies of JSON each side wrote in its own layout: compare the data
            if (n.StartsWith("index.json", StringComparison.Ordinal)) Assert.True(JsonNode.DeepEquals(Norm(JsonNode.Parse(want)), Norm(JsonNode.Parse(got))), $"[{label}] {n}");
            else Assert.True(want == got, $"[{label}] {n}\n--- want\n{want}\n--- got\n{got}");
        }
    }

    /// Numbers compared as doubles (Swift writes 750 for 750.0)
    static JsonNode? Norm(JsonNode? n) => n switch
    {
        JsonObject o => new JsonObject(o.Select(kv => KeyValuePair.Create(kv.Key, Norm(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(Norm).ToArray()),
        JsonValue v when v.TryGetValue<double>(out var d) => JsonValue.Create(d),
        _ => n?.DeepClone(),
    };

    [Fact]
    public void Misc()
    {
        using var sb = new Sandbox();
        foreach (var c in Cases("misc"))
        {
            switch (S(c!["fn"]))
            {
                case "ts": Assert.Equal(S(c["expected"]), Fmt.Ts(I(c["ms"]))); break;
                case "dur": Assert.Equal(S(c["expected"]), Fmt.Dur(D(c["seconds"]))); Assert.Equal(D(c["clamped"]), Fmt.ClampSeconds(D(c["seconds"]))); break;
                case "splitFolder":
                    var (d, t) = MeetingIndex.Split(S(c["input"]));
                    Assert.Equal((S(c["date"]), S(c["title"])), (d, t)); break;
                case "safeTitle": Assert.Equal(S(c["expected"]), Paths.SafeTitle(S(c["input"]), windowsRules: false)); break;
                case "urlProblem":
                    Assert.Equal(SN(c["expected"]), LocalEndpoint.UrlProblem(S(c["input"])));
                    Assert.Equal(S(c["root"]), LocalEndpoint.Root(S(c["input"]))); break;
                case "contextFor": Assert.Equal(IN(c["expected"]), LocalEndpoint.ContextFor(I(c["system"]), I(c["user"]), I(c["maxOutput"]), I(c["cap"]))); break;
                case "maxContextTokens": Assert.Equal(I(c["expected"]), LocalEndpoint.MaxContextTokens((ulong)I(c["gb"]) * 1_073_741_824UL)); break;
                case "stripThinking": Assert.Equal(S(c["expected"]), LocalEndpoint.StripThinking(S(c["input"]))); break;
                case "cliExplain":
                    var r = new RunResult(I(c["status"]), S(c["stdout"]), S(c["stderr"]), B(c["timedOut"]));
                    Assert.Equal(SN(c["expected"]), CLIFailure.Explain(r, "Claude", 900));
                    Assert.Equal(S(c["tail"]), CLIFailure.Tail(r)); break;
                case "bigram":
                    Assert.Equal(SL(c["bigramsA"]), Transcriber.Bigrams(S(c["a"])).OrderBy(x => x, StringComparer.Ordinal).ToList());
                    Assert.Equal(D(c["containment"]), Transcriber.BigramContainment(S(c["a"]), S(c["b"])), 12); break;
            }
        }
    }

    // ── end to end: a fake whisper engine returns canned JSON by slice name; a fake m4a encoder ──

    sealed class FakeWhisper(string dir) : IWhisperEngine
    {
        public bool Available => true;
        public WhisperRun Run(string model, string wav, string jsonBase, int maxContext, double timeoutSeconds, bool allowGpu)
        {
            var src = Path.Combine(dir, Path.GetFileName(jsonBase) + ".json");
            File.WriteAllText(jsonBase + ".json", File.Exists(src) ? File.ReadAllText(src) : "{\"transcription\":[]}");
            return new WhisperRun(0, "", UsedGpu: false);
        }
    }

    sealed class FakeM4a : IM4aEncoder
    {
        public bool Mix(string dir, string dest, double seconds) { File.WriteAllText(dest, "m4a"); return true; }
        public double? DurationSeconds(string path) => null;
    }

    [Fact]
    public void PipelineEndToEnd()
    {
        using var sb = new Sandbox();
        Directory.CreateDirectory(Paths.Models);
        File.WriteAllText(Path.Combine(Paths.Models, ModelCatalog.TurboQ5.File), "fake");
        Platform.M4a = new FakeM4a();
        try
        {
            foreach (var c in Cases("pipeline_e2e"))
            {
                var name = S(c!["name"]);
                var wdir = Path.Combine(sb.Box, "whisper-" + name);
                Directory.CreateDirectory(wdir);
                foreach (var kv in c["whisper"]!.AsObject())
                    File.WriteAllText(Path.Combine(wdir, kv.Key + ".json"), new JsonObject { ["transcription"] = kv.Value!.DeepClone() }.ToJsonString());
                Transcriber.Engine = new FakeWhisper(wdir);
                var dir = Path.Combine(Pipeline.RecordingsDir, "rec-e2e-" + name);
                Directory.CreateDirectory(dir);
                if (c["mic"] is JsonArray mic) WavIO.WritePcmFile(Path.Combine(dir, "mic.wav"), Sandbox.Synth(mic));
                if (c["sys"] is JsonArray sys) WavIO.WritePcmFile(Path.Combine(dir, "system.wav"), Sandbox.Synth(sys));
                var m = c["meta"]!;
                var meta = new MeetingMeta
                {
                    Started = DateTimeOffset.Parse(S(c["started"])), Title = S(m["title"]), Attendees = S(m["attendees"]), Scene = SN(m["scene"]), Source = SN(m["source"]),
                    Seconds = D(m["seconds"]), MicMax = (float)D(m["micMax"]), SysMax = (float)D(m["sysMax"]),
                    Pauses = m["pauses"] is JsonArray ps ? ps.Select(Span).ToList() : null,
                };
                var fake = new FakeProvider("fake", SN(c["reply"]), SN(c["err"]));
                IProvider provider = B(c["providerNone"]) ? new NoneProvider() : fake;
                var r = new Pipeline().Process(dir, meta, provider);
                string Norm(string s) => s.Replace(dir, "{WORK}").Replace(Paths.Root, "{ROOT}").Replace('\\', '/');
                var md = Norm(File.ReadAllText(r.MdPath));
                Assert.Equal(S(c["mdName"]), Path.GetFileName(r.MdPath));
                Assert.True(S(c["md"]) == md, $"[{name}] md differs\n--- want\n{S(c["md"])}\n--- got\n{md}");
                Assert.Equal(S(c["transcript"]), Norm(File.ReadAllText(Path.Combine(dir, "transcript.md"))));
                Assert.Equal(S(c["summary"]), r.Summary);
                Assert.Equal(SN(c["polishErr"]), r.PolishErr);
                if (!B(c["providerNone"]))
                {
                    Assert.True(SN(c["seenSystem"]) == (fake.SeenSystem is { } ss ? Norm(ss) : null), $"[{name}] system prompt differs");
                    Assert.True(SN(c["seenUser"]) == (fake.SeenUser is { } su ? Norm(su) : null), $"[{name}] user message differs\n--- want\n{SN(c["seenUser"])}\n--- got\n{fake.SeenUser}");
                }
            }
        }
        finally { Transcriber.Engine = null; Platform.M4a = null; }
    }

    /// Replays meeting_rename: write a file (path relative to the sandbox: root/…, support/…, mirror/…; {MEETINGS} = the meetings
    /// folder's absolute path), write a meta.json, sync one meeting, rename one. After each rename these must match: the report, the
    /// meetings tree, each meeting's meta title / outName, the work folders' meta, four memory files, index, .hearby-written.json,
    /// which meetings .hearby-names.json knows, memory backups, the mirror folder, every meeting's main record
    [Fact]
    public void MeetingRenameSteps()
    {
        using var sb = new Sandbox();
        var day = new MemoryStore.Backups().Day;
        var mirror = "";
        string Expand(string s) => s.Rep("{MEETINGS}", Paths.Meetings);
        string NormText(string s)
        {
            var t = s.Rep(Paths.Meetings, "{MEETINGS}");
            return Path.DirectorySeparatorChar == '\\' ? t.Replace('\\', '/') : t;
        }
        static JsonArray Arr(IEnumerable<string> xs) => new(xs.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());
        static IEnumerable<string> Names(string dir, bool dirsOnly = false) =>
            (dirsOnly ? Directory.EnumerateDirectories(dir) : Directory.EnumerateFileSystemEntries(dir)).Select(x => Path.GetFileName(x)).Where(n => !n.Starts(".")).OrderBy(x => x, StringComparer.Ordinal);
        static JsonNode? MetaOf(string dir) => MeetingMeta.Load(dir) is { } m ? new JsonObject { ["title"] = m.Title, ["outName"] = m.OutName } : null;
        foreach (var st in Cases("meeting_rename"))
        {
            switch (S(st!["op"]))
            {
                case "config":
                    mirror = Path.Combine(sb.Box, S(st["mirror"]));
                    ConfigStore.Shared.Update(x => { x.MemoryEnabled = B(st["memoryEnabled"]); x.MirrorDir = mirror; });
                    MemoryStore.Ensure();
                    break;
                case "write":
                {
                    var p = Path.Combine(sb.Box, S(st["path"]));
                    Directory.CreateDirectory(Path.GetDirectoryName(p)!);
                    File.WriteAllText(p, Expand(S(st["text"])));
                    break;
                }
                case "meta":
                {
                    var d = Path.Combine(sb.Box, S(st["path"]));
                    Directory.CreateDirectory(d);
                    MeetingMeta.Save(new MeetingMeta { Id = S(st["work"]), Title = S(st["title"]), OutName = S(st["outName"]), Started = DateTimeOffset.Parse(S(st["started"])) }, d);
                    break;
                }
                case "sync":
                    MemoryStore.Sync(Path.Combine(sb.Box, S(st["path"])));
                    break;
                case "rename":
                {
                    var label = $"{S(st["folder"])} → {S(st["title"])}";
                    var r = MeetingRename.Rename(Path.Combine(Paths.Meetings, S(st["folder"])), S(st["title"]));
                    var want = st["report"]!;
                    Assert.Equal(S(want["oldID"]), r.OldId);
                    Assert.Equal(S(want["newID"]), r.NewId);
                    Assert.Equal(S(want["dir"]), EntryFiles.RelativeToRoot(r.Dir));
                    Assert.Equal(SN(want["md"]), r.MdPath == null ? null : EntryFiles.RelativeToRoot(r.MdPath));
                    Assert.Equal(SL(want["renamed"]), r.Renamed);
                    Assert.Equal(SL(want["memory"]), r.Memory);
                    Assert.Equal(SL(want["backups"]), r.Backups.Select(b => Path.GetFileName(b).Rep(day, "{DAY}")).ToList());
                    Assert.Equal(SL(want["mirror"]), r.Mirror.Select(x => Path.GetFileName(x)).ToList());
                    Assert.Equal(SL(want["warnings"]), r.Warnings);
                    Assert.True(B(want["unchanged"]) == r.Unchanged, $"[{label}] unchanged");

                    var after = st["after"]!;
                    var tree = new JsonObject();
                    var metas = new JsonObject();
                    var records = new JsonObject();
                    foreach (var d in Names(Paths.Meetings, dirsOnly: true))
                    {
                        var dir = Path.Combine(Paths.Meetings, d);
                        tree[d] = Arr(Names(dir));
                        metas[d] = MetaOf(dir);
                        if (MeetingRename.MainRecord(dir) is { } md) records[d] = NormText(File.ReadAllText(md));
                    }
                    var work = new JsonObject();
                    if (Directory.Exists(Pipeline.RecordingsDir)) foreach (var w in Names(Pipeline.RecordingsDir, dirsOnly: true)) work[w] = MetaOf(Path.Combine(Pipeline.RecordingsDir, w));
                    foreach (var (key, got) in new (string, JsonNode?)[] { ("tree", tree), ("meta", metas), ("work", work), ("records", records) })
                        Assert.True(JsonNode.DeepEquals(Norm(after[key]), Norm(got)), $"[{label}] {key}\n--- want\n{after[key]}\n--- got\n{got}");
                    foreach (var kv in after["files"]!.AsObject())
                    {
                        var got = File.ReadAllText(Path.Combine(Paths.Memory, kv.Key));
                        Assert.True(S(kv.Value) == got, $"[{label}] {kv.Key}\n--- want\n{S(kv.Value)}\n--- got\n{got}");
                    }
                    foreach (var (f, key) in new[] { ("index.json", "index"), (MemoryStore.WrittenBook, "written") })
                    {
                        var got = JsonNode.Parse(File.ReadAllText(Path.Combine(Paths.Memory, f)));
                        Assert.True(JsonNode.DeepEquals(Norm(after[key]), Norm(got)), $"[{label}] {f}\n--- want\n{after[key]}\n--- got\n{got}");
                    }
                    var names = JsonNode.Parse(File.ReadAllText(Path.Combine(Paths.Memory, NameLedger.StateFile)))!["written"]!.AsObject().Select(kv => kv.Key).OrderBy(x => x, StringComparer.Ordinal).ToList();
                    Assert.Equal(SL(after["names"]), names);
                    Assert.Equal(SL(after["backups"]), Directory.EnumerateFiles(Paths.Memory).Select(x => Path.GetFileName(x)).Where(n => n.Has(".bak-")).Select(n => n.Rep(day, "{DAY}")).OrderBy(x => x, StringComparer.Ordinal).ToList());
                    Assert.Equal(SL(after["mirror"]), Names(mirror).ToList());
                    break;
                }
                default: throw new Exception("unknown op " + S(st["op"]));
            }
        }
    }
}
