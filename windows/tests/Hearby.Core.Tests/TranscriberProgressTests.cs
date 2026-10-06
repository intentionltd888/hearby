// Windows-only behaviour of the transcriber (no macOS fixture): the engine is probed before slices are planned, a resumed run
// cuts the way the first one did, and 「約剩」 covers the tracks still waiting.
using Hearby.Core;

namespace Hearby.Core.Tests;

public class TranscriberProgressTests
{
    sealed class ProgressEngine(bool? probe) : IWhisperEngine
    {
        public readonly List<string> Runs = [];
        public int Probes;
        public bool Available => true;
        public bool? Probe(string model, bool allowGpu) { Probes++; return probe; }
        public WhisperRun Run(string model, string wav, string jsonBase, int maxContext, double timeoutSeconds, bool allowGpu, Action<int>? onProgress = null)
        {
            Runs.Add(Path.GetFileName(jsonBase));
            onProgress?.Invoke(50);
            File.WriteAllText(jsonBase + ".json", "{\"transcription\":[{\"offsets\":{\"from\":0,\"to\":2000},\"text\":\"測試一下。\"}]}");
            return new WhisperRun(0, "", probe == true);
        }
    }

    static (string Wav, string Dir) TwelveMinutes(Sandbox sb) => Minutes(sb, 12);

    static (string Wav, string Dir) Minutes(Sandbox sb, int minutes)
    {
        Directory.CreateDirectory(Paths.Models);
        File.WriteAllText(Path.Combine(Paths.Models, ModelCatalog.TurboQ5.File), "fake");
        var dir = Path.Combine(sb.Box, "rec");
        Directory.CreateDirectory(dir);
        var wav = Path.Combine(dir, "mic.wav");
        WavIO.WritePcmFile(wav, Sandbox.Synth([new System.Text.Json.Nodes.JsonArray(minutes * 60, 8000)]));
        return (wav, dir);
    }

    [Fact]
    public void ShortTrackIsNotProbedAndUsesLastMeetingsSpeed()
    {
        using var sb = new Sandbox();
        var (wav, dir) = Minutes(sb, 3);
        // one slice whatever the engine: no extra model load; the estimate comes from what this PC did last time
        ConfigStore.Shared.Update(c => { c.WhisperBackend = "Cpu gpu=0（8 執行緒）"; c.WhisperSpeedCPU = 0.5; });
        var engine = new ProgressEngine(false);
        Transcriber.Engine = engine;
        try
        {
            var stages = new List<string>();
            new Transcriber { OnStage = stages.Add }.Transcribe(wav, "我方", "房間裡（麥克風）", dir, "mic");
            Assert.Equal(0, engine.Probes);
            Assert.Equal(["mic-w00"], engine.Runs);
            Assert.Equal("聽打房間裡（麥克風）・約剩 6 分鐘", stages[0]);
        }
        finally { Transcriber.Engine = null; }
    }

    [Fact]
    public void EtaInWholeMinutes()
    {
        Assert.Equal("・剩不到 1 分鐘", Transcriber.EtaText(59));
        Assert.Equal("・約剩 1 分鐘", Transcriber.EtaText(60));
        Assert.Equal("・約剩 8 分鐘", Transcriber.EtaText(465));
        Assert.Equal("・約剩 1 小時 5 分", Transcriber.EtaText(3900));
    }

    [Fact]
    public void CpuProbeCutsFiveMinuteSlicesAndCountsLaterTracks()
    {
        using var sb = new Sandbox();
        var (wav, dir) = TwelveMinutes(sb);
        ConfigStore.Shared.Update(c => c.WhisperSpeedCPU = 1.0);
        var engine = new ProgressEngine(false);
        Transcriber.Engine = engine;
        try
        {
            var stages = new List<string>();
            var tr = new Transcriber { OnStage = stages.Add, LaterMs = 600_000 };
            var segs = tr.Transcribe(wav, "我方", "房間裡（麥克風）", dir, "mic");
            Assert.Equal(["mic-w00", "mic-w01", "mic-w02"], engine.Runs);
            Assert.Equal("300000", File.ReadAllText(Path.Combine(dir, "mic.slicems")));
            // 12 minutes of this track + 10 of the next one at the last meeting's speed (1×)
            Assert.Equal("聽打房間裡（麥克風） 1/3・約剩 22 分鐘（本機以 CPU 轉寫，較慢）", stages[0]);
            Assert.Contains(stages, s => s.StartsWith("聽打房間裡（麥克風） 3/3・約剩 ", StringComparison.Ordinal));
            Assert.Single(segs);   // the same line three times in a row is kept once
            Assert.False(tr.UsedGpu);
        }
        finally { Transcriber.Engine = null; }
    }

    [Fact]
    public void ResumedRunKeepsTheFirstRunsSlices()
    {
        using var sb = new Sandbox();
        var (wav, dir) = TwelveMinutes(sb);
        File.WriteAllText(Path.Combine(dir, "mic.slicems"), "900000");
        var engine = new ProgressEngine(false);
        Transcriber.Engine = engine;
        try
        {
            new Transcriber().Transcribe(wav, "我方", "房間裡（麥克風）", dir, "mic");
            Assert.Equal(["mic-w00"], engine.Runs);
        }
        finally { Transcriber.Engine = null; }
    }

    [Fact]
    public void GpuProbeKeepsFifteenMinuteSlices()
    {
        using var sb = new Sandbox();
        var (wav, dir) = TwelveMinutes(sb);
        var engine = new ProgressEngine(true);
        Transcriber.Engine = engine;
        try
        {
            var stages = new List<string>();
            var tr = new Transcriber { OnStage = stages.Add };
            tr.Transcribe(wav, "我方", "房間裡（麥克風）", dir, "mic");
            Assert.Equal(["mic-w00"], engine.Runs);
            Assert.Equal("聽打房間裡（麥克風）…", stages[0]);
            Assert.True(tr.UsedGpu);
        }
        finally { Transcriber.Engine = null; }
    }
}
