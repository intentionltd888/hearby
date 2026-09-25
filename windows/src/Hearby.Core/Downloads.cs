// Downloads — speech model download (resumable, verified; source = official Hugging Face + optional mirror). Mirrors Downloads.swift.
//
// Windows default = large-v3-turbo quantised to q5_0 (574 MB): a third of the full model's size and memory, the tier the
// performance notes recommend for ordinary office laptops. A full ggml-large-v3-turbo.bin in the models folder is used if present.
using System.Net.Http;
using System.Security.Cryptography;

namespace Hearby.Core;

public static class ModelCatalog
{
    public sealed record Spec(string Id, string File, long Bytes, string? Sha256, string[] Urls);

    public static readonly Spec TurboQ5 = new("whisper-turbo-q5", "ggml-large-v3-turbo-q5_0.bin", 574_041_195,
        "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        ["https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"]);

    public static readonly Spec Turbo = new("whisper-turbo", "ggml-large-v3-turbo.bin", 1_624_555_275,
        "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        ["https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"]);

    public static Spec Default => ConfigStore.Shared.Current.WhisperModel == Turbo.File ? Turbo : TurboQ5;

    /// Sources: the user's mirror (optional) → official
    public static List<string> Sources(Spec s)
    {
        var outList = new List<string>();
        var m = ConfigStore.Shared.Current.ModelMirror;
        if (!string.IsNullOrEmpty(m)) outList.Add(m.Ends("/") ? m + s.File : m + "/" + s.File);
        outList.AddRange(s.Urls);
        return outList;
    }

    /// The model file to use; null = needs a download
    public static string? InstalledModel()
    {
        var want = ConfigStore.Shared.Current.WhisperModel;
        var cands = new List<string>();
        if (!string.IsNullOrEmpty(want)) cands.Add(Path.Combine(Paths.Models, want));
        cands.Add(Path.Combine(Paths.Models, TurboQ5.File));
        cands.Add(Path.Combine(Paths.Models, Turbo.File));
        return cands.FirstOrDefault(File.Exists);
    }

    public static Spec? SpecFor(string file) => file == TurboQ5.File ? TurboQ5 : file == Turbo.File ? Turbo : null;
}

public sealed class ModelDownload
{
    public enum Phases { Downloading, Verifying, Done, Failed }
    public ModelCatalog.Spec Spec { get; }
    public string Dest { get; }
    public double Fraction { get; private set; }
    public Phases Phase { get; private set; } = Phases.Downloading;
    public long BytesWritten { get; private set; }
    public string? Error { get; private set; }

    public static double StallSeconds = 45;
    public static int MaxRounds = 6;
    static readonly HttpClient Http = new(new SocketsHttpHandler { AutomaticDecompression = System.Net.DecompressionMethods.None }) { Timeout = Timeout.InfiniteTimeSpan };
    static string WorkDir => Path.Combine(Paths.Support, "downloads");
    string PartFile => Path.Combine(WorkDir, Spec.File + ".part");
    readonly CancellationTokenSource userCancel = new();
    readonly Action<string?, string?> done;

    ModelDownload(ModelCatalog.Spec spec, Action<string?, string?> done)
    {
        Spec = spec;
        Dest = Path.Combine(Paths.Models, spec.File);
        this.done = done;
    }

    /// done(path, null) on success or done(null, error)
    public static ModelDownload Start(ModelCatalog.Spec spec, Action<string?, string?> done)
    {
        var d = new ModelDownload(spec, done);
        Task.Run(d.RunAsync);
        return d;
    }

    public void Cancel() => userCancel.Cancel();

    async Task RunAsync()
    {
        try
        {
            Directory.CreateDirectory(Paths.Models);
            Directory.CreateDirectory(WorkDir);
            if (DiskShortfallMessage(Spec.Bytes) is { } msg) { Finish(null, msg); return; }
            var sources = ModelCatalog.Sources(Spec);
            string lastReason = "未知錯誤";
            for (int round = 1; round <= MaxRounds; round++)
            {
                foreach (var url in sources)
                {
                    if (userCancel.IsCancellationRequested) { Finish(null, "已取消"); return; }
                    var (ok, reason) = await AttemptAsync(url, round);
                    if (ok)
                    {
                        Phase = Phases.Verifying;
                        var size = new FileInfo(PartFile).Length;
                        if (Spec.Bytes > 0 && size != Spec.Bytes) { lastReason = "下載不完整"; continue; }
                        if (Spec.Sha256 is { } want && Sha256Of(PartFile) != want)
                        {
                            try { File.Delete(PartFile); } catch { }
                            lastReason = "檔案校驗失敗（內容與官方不符），已丟棄重抓";
                            Phase = Phases.Downloading;
                            continue;
                        }
                        File.Move(PartFile, Dest, overwrite: true);
                        Fraction = 1; Phase = Phases.Done;
                        HearbyLog.Write($"download done {Spec.File} {size} bytes");
                        Finish(Dest, null);
                        return;
                    }
                    lastReason = reason;
                    HearbyLog.Write($"download fail r{round} {new Uri(url).Host}: {reason}");
                }
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, round - 1))));
            }
            Finish(null, $"下載失敗：所有來源輪流試了 {MaxRounds} 輪（最後原因：{lastReason}）。已下載的部分有保留，按重試會從斷點接續");
        }
        catch (Exception e) { Finish(null, "下載失敗：" + e.Message); }
    }

    async Task<(bool, string)> AttemptAsync(string url, int round)
    {
        long offset = File.Exists(PartFile) ? new FileInfo(PartFile).Length : 0;
        if (Spec.Bytes <= 0 || offset > Spec.Bytes) offset = 0;
        if (Spec.Bytes > 0 && offset == Spec.Bytes) return (true, "");
        BytesWritten = offset;
        if (Spec.Bytes > 0) Fraction = Math.Min(0.999, (double)offset / Spec.Bytes);
        HearbyLog.Write($"download attempt r{round} {new Uri(url).Host} offset={offset / 1_048_576}MB");
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(userCancel.Token);
        var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.UserAgent.ParseAdd($"Hearby-Windows/{HearbyVersion.Build}");
        if (offset > 0) req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(offset, null);
        var lastActivity = DateTime.UtcNow;
        using var watchdog = new Timer(_ => { if ((DateTime.UtcNow - lastActivity).TotalSeconds > StallSeconds) try { stall.Cancel(); } catch { } }, null, 5000, 5000);
        try
        {
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, stall.Token);
            int status = (int)resp.StatusCode;
            FileMode mode;
            if (status == 206)
            {
                var start = resp.Content.Headers.ContentRange?.From ?? -1;
                if (start != offset) { try { File.Delete(PartFile); } catch { } return (false, "續傳起點不符"); }
                mode = FileMode.Append;
            }
            else if (status == 200) { mode = FileMode.Create; offset = 0; }
            else if (status == 416 && Spec.Bytes > 0 && offset >= Spec.Bytes) return (true, "");
            else return (false, $"伺服器回應 {status}");
            await using var net = await resp.Content.ReadAsStreamAsync(stall.Token);
            await using var fs = new FileStream(PartFile, mode, FileAccess.Write, FileShare.Read, 1 << 20);
            var buf = new byte[1 << 20];
            while (true)
            {
                int n = await net.ReadAsync(buf, stall.Token);
                if (n == 0) break;
                lastActivity = DateTime.UtcNow;
                await fs.WriteAsync(buf.AsMemory(0, n), stall.Token);
                offset += n;
                BytesWritten = offset;
                if (Spec.Bytes > 0)
                {
                    if (offset > Spec.Bytes) { fs.Close(); try { File.Delete(PartFile); } catch { } return (false, "內容超出預期大小（來源給錯檔）"); }
                    Fraction = Math.Min(0.999, (double)offset / Spec.Bytes);
                }
            }
            await fs.FlushAsync();
            if (Spec.Bytes > 0 && offset != Spec.Bytes) return (false, $"下載中斷（收到 {offset / 1_048_576}MB／應為 {Spec.Bytes / 1_048_576}MB）");
            return (true, "");
        }
        catch (OperationCanceledException) when (!userCancel.IsCancellationRequested) { return (false, $"來源停滯（{(int)StallSeconds} 秒沒有任何資料）"); }
        catch (OperationCanceledException) { return (false, "已取消"); }
        catch (Exception e) { return (false, e.Message); }
    }

    void Finish(string? path, string? error)
    {
        if (error != null) { Phase = Phases.Failed; Error = error; }
        try { done(path, error); } catch { }
    }

    public static string? Sha256Of(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
            return Convert.ToHexStringLower(SHA256.HashData(fs));
        }
        catch { return null; }
    }

    public static string? DiskShortfallMessage(long need)
    {
        try
        {
            Directory.CreateDirectory(Paths.Support);
            var root = Path.GetPathRoot(Path.GetFullPath(Paths.Support));
            if (root == null) return null;
            var free = new DriveInfo(root).AvailableFreeSpace;
            long want = need + 500L * 1_048_576;
            if (free >= want) return null;
            static string Gb(long b) => (b / 1_000_000_000.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " GB";
            return $"磁碟空間不足：這顆模型需要約 {Gb(need)}，目前只剩 {Gb(free)}。請清出空間後再試";
        }
        catch { return null; }
    }
}
