// WhisperWorker — `Hearby.exe --transcribe-worker …`: transcribes one wav slice and writes whisper-cli style JSON
// ({"transcription":[{"offsets":{"from":ms,"to":ms},"text":"…"}]}), the same shape the macOS parser reads.
// Settings mirror the macOS whisper-cli call: zh, the Taiwanese prompt carried across windows, beam search 5,
// temperature 0 (+0.2 fallback), entropy 2.4, log-prob −1, no-speech 0.6; "--max-context 16" for the retry pass.
// GPU: Vulkan when allowed and present, else CPU (AVX2) → CPU without AVX. The engine's own log says whether a GPU device
// was really used (the Vulkan build still runs on the CPU when the machine has no Vulkan GPU); the result goes to stderr as
// "hearby-backend: <library> gpu=0|1 <device>" for the parent.
using System.Text;
using System.Text.Json.Nodes;
using Whisper.net;
using Whisper.net.LibraryLoader;
using Whisper.net.Logger;

namespace Hearby.App;

static class WhisperWorker
{
    public const int SoftwareGpuExit = 3;
    static readonly string[] SoftwareGpu = ["Basic Render", "llvmpipe", "SwiftShader", "WARP", "lavapipe"];

    public static int Run(string[] args)
    {
        string? Arg(string k) { int i = Array.IndexOf(args, k); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
        var model = Arg("--model"); var wav = Arg("--wav"); var outPath = Arg("--out");
        if (model == null || wav == null || outPath == null) { Console.Error.WriteLine("usage: --transcribe-worker --model M --wav W --out J"); return 2; }
        int threads = int.TryParse(Arg("--threads"), out var t) ? t : 4;
        int maxContext = int.TryParse(Arg("--max-context"), out var mc) ? mc : -1;
        bool gpu = Arg("--gpu") != "0";
        var prompt = Arg("--prompt") ?? Hearby.Core.Transcriber.Prompt;
        var native = new List<string>();
        using var logSub = LogProvider.AddLogger((level, msg) =>
        {
            if (string.IsNullOrWhiteSpace(msg)) return;
            lock (native) native.Add(msg.Trim());
            if (level == WhisperLogLevel.Error) Console.Error.WriteLine("whisper: " + msg.Trim());
        });
        try
        {
            RuntimeOptions.RuntimeLibraryOrder = gpu
                ? [RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx]
                : [RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx];
            using var factory = OpenModel(model, gpu);
            var builder = factory.CreateBuilder()
                .WithLanguage("zh")
                .WithThreads(threads)
                .WithPrompt(prompt)
                .WithCarryInitialPrompt(true)
                .WithTemperature(0f)
                .WithTemperatureInc(0.2f)
                .WithEntropyThreshold(2.4f)
                .WithLogProbThreshold(-1f)
                .WithNoSpeechThreshold(0.6f)
                .WithBeamSearchSamplingStrategy(b => b.WithBeamSize(5));
            if (maxContext >= 0) builder = builder.WithMaxLastTextTokens(maxContext);
            using var processor = builder.Build();
            string[] lines; lock (native) lines = [.. native];
            bool usedGpu = gpu && lines.Any(l => l.Contains("using Vulkan", StringComparison.OrdinalIgnoreCase)) && !lines.Any(l => l.Contains("no GPU found", StringComparison.OrdinalIgnoreCase));
            var device = lines.FirstOrDefault(l => l.StartsWith("ggml_vulkan: 0 = ", StringComparison.Ordinal))?["ggml_vulkan: 0 = ".Length..].Split('|')[0].Trim() ?? "";
            Console.Error.WriteLine($"hearby-backend: {RuntimeOptions.LoadedLibrary?.ToString() ?? "unknown"} gpu={(usedGpu ? 1 : 0)} {device}".TrimEnd());
            // A "GPU" that is really the CPU drawing in software (virtual machines, remote desktops, missing drivers) is slower
            // than the CPU engine itself: tell the parent to run on the CPU instead
            if (usedGpu && SoftwareGpu.Any(k => device.Contains(k, StringComparison.OrdinalIgnoreCase))) return SoftwareGpuExit;
            var samples = ReadWav(wav);
            var list = new JsonArray();
            var task = Task.Run(async () =>
            {
                await foreach (var seg in processor.ProcessAsync(samples))
                    list.Add(new JsonObject
                    {
                        ["offsets"] = new JsonObject { ["from"] = (int)seg.Start.TotalMilliseconds, ["to"] = (int)seg.End.TotalMilliseconds },
                        ["text"] = seg.Text,
                    });
            });
            task.GetAwaiter().GetResult();
            var tmp = outPath + ".tmp";
            File.WriteAllText(tmp, new JsonObject { ["transcription"] = list }.ToJsonString(), new UTF8Encoding(false));
            File.Move(tmp, outPath, overwrite: true);
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("hearby-worker-error: " + e.GetType().Name + ": " + e.Message);
            return 1;
        }
    }

    /// Model paths may contain Chinese characters. The process runs with a UTF-8 ANSI code page (app.manifest) so the native
    /// engine can open them; if that still fails, the model is handed over as a buffer instead of a path.
    static WhisperFactory OpenModel(string path, bool gpu)
    {
        var opts = new WhisperFactoryOptions { UseGpu = gpu };
        try { return WhisperFactory.FromPath(path, opts); }
        catch (Exception e) when (path.Any(c => c > 127))
        {
            Console.Error.WriteLine("hearby-worker: path load failed (" + e.Message + "), loading from memory");
            return WhisperFactory.FromBuffer(File.ReadAllBytes(path), opts);
        }
    }

    /// 16 kHz mono s16 wav → floats (reads the PCM range, header length fields are not trusted)
    static float[] ReadWav(string path)
    {
        var r = Hearby.Core.WavIO.PcmRange(path) ?? throw new Exception("wav unreadable");
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        fs.Seek(r.Start, SeekOrigin.Begin);
        var bytes = new byte[r.Bytes];
        int got = 0;
        while (got < bytes.Length) { int k = fs.Read(bytes, got, bytes.Length - got); if (k <= 0) break; got += k; }
        var outArr = new float[got / 2];
        for (int i = 0; i < outArr.Length; i++) outArr[i] = BitConverter.ToInt16(bytes, i * 2) / 32768f;
        return outArr;
    }
}
