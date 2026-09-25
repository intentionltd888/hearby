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
                Baseline = SN(c["baseline"]), History = SL(c["history"]),
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
            MemoryStore.AppendMeeting(md);
            foreach (var kv in st["files"]!.AsObject())
                Assert.True(S(kv.Value) == File.ReadAllText(Path.Combine(Paths.Memory, kv.Key)), $"step {I(st["step"])} {kv.Key}\n--- want\n{S(kv.Value)}\n--- got\n{File.ReadAllText(Path.Combine(Paths.Memory, kv.Key))}");
            var idx = JsonNode.Parse(File.ReadAllText(Path.Combine(Paths.Memory, "index.json")));
            Assert.True(JsonNode.DeepEquals(Norm(st["index"]), Norm(idx)), $"index.json step {I(st["step"])}\n--- want\n{st["index"]}\n--- got\n{idx}");
        }
        Assert.Equal(SL(c["openItems"]), MemoryStore.OpenItems());
        foreach (var kv in c["parseDur"]!.AsObject()) Assert.Equal(D(kv.Value), MemoryStore.ParseDur(kv.Key));
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
}
