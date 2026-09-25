// MediaImport — an existing audio or video file → mic.wav (16 kHz mono s16), streamed chunk by chunk (hours of audio never
// sit in memory). Mirrors Audio/MediaImporter.swift; decoding is Windows Media Foundation (the same engine the Films & TV
// and Media Player apps use), AIFF through NAudio's own reader. Problems are found before a work folder is made.
using Hearby.Core;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Hearby.App;

static class MediaImport
{
    public static readonly string[] AudioExts = ["m4a", "mp3", "wav", "aac", "wma", "flac", "aiff", "aif"];
    public static readonly string[] VideoExts = ["mp4", "mov", "m4v", "wmv", "avi", "mkv"];
    public static IEnumerable<string> AllExts => AudioExts.Concat(VideoExts);
    public static string FileDialogFilter =>
        "音檔或影片|" + string.Join(";", AllExts.Select(e => "*." + e)) + "|所有檔案|*.*";

    public sealed record Probe(string Path, double Seconds);

    static WaveStream Open(string path)
    {
        var ext = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (ext is "aiff" or "aif") return new AiffReader(path);
        WinPlatform.StartMediaFoundation();
        return new MediaFoundationReader(path, new MediaFoundationReader.MediaFoundationReaderSettings { RequestFloatOutput = true });
    }

    public static Probe Check(string path)
    {
        var name = System.IO.Path.GetFileName(path);
        if (Directory.Exists(path)) throw new HearbyError($"「{name}」是資料夾，請選裡面的音檔或影片");
        if (!File.Exists(path)) throw new HearbyError($"找不到這個檔案：{name}");
        var ext = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (!AllExts.Contains(ext))
            throw new HearbyError($"不支援的檔案格式（.{ext}）。支援 {string.Join("／", AudioExts)} 音檔與 {string.Join("／", VideoExts)} 影片");
        try { using var fs = File.OpenRead(path); }
        catch { throw new HearbyError($"沒有權限讀取「{name}」"); }
        try
        {
            using var r = Open(path);
            var secs = r.TotalTime.TotalSeconds;
            if (!double.IsFinite(secs) || secs <= 0) throw new HearbyError("檔案無法讀取或已損壞");
            return new Probe(path, secs);
        }
        catch (HearbyError) { throw; }
        catch (Exception e)
        {
            HearbyLog.Write($"import probe fail {ext}: {e.GetType().Name} {e.Message}");
            var m = e.Message;
            // MF_E_INVALIDSTREAMNUMBER: the file has no audio stream to select ("The stream number provided was invalid")
            if (m.Contains("0xC00D36B3", StringComparison.OrdinalIgnoreCase) || m.Contains("0xC00D36B4", StringComparison.OrdinalIgnoreCase)
                || m.Contains("no audio", StringComparison.OrdinalIgnoreCase) || m.Contains("stream number", StringComparison.OrdinalIgnoreCase)
                || (e.HResult is unchecked((int)0xC00D36B3)))
                throw new HearbyError("檔案裡沒有聲音軌（純畫面的錄影無法轉逐字稿）");
            if (m.Contains("0xC00D36C4", StringComparison.OrdinalIgnoreCase))
                throw new HearbyError($"這台電腦讀不了這種格式（.{ext}）：可以先轉成 mp3 或 m4a 再匯入");
            if (m.Contains("DRM", StringComparison.OrdinalIgnoreCase) || m.Contains("0xC00D7", StringComparison.OrdinalIgnoreCase))
                throw new HearbyError("這個檔案受 DRM 保護，無法讀取聲音。請改用無保護的來源檔");
            throw new HearbyError($"「{name}」無法讀取（檔案損壞或格式不支援）");
        }
    }

    /// Returns the seconds actually written (more trustworthy than the container's duration)
    public static double Transcode(Probe p, string dest, Action<double>? progress = null, CancellationToken ct = default)
    {
        using var reader = Open(p.Path);
        ISampleProvider sp = reader.ToSampleProvider();
        if (sp.WaveFormat.Channels > 1) sp = new DownmixToMono(sp);
        if (sp.WaveFormat.SampleRate != WavIO.SampleRate) sp = new WdlResamplingSampleProvider(sp, WavIO.SampleRate);
        using var w = new CrashSafeWavWriter(dest);
        var buf = new float[WavIO.SampleRate];   // one second
        var pcm = new short[buf.Length];
        long total = 0;
        double lastFrac = -1;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            int n = sp.Read(buf.AsSpan());
            if (n <= 0) break;
            for (int i = 0; i < n; i++) pcm[i] = (short)(Math.Clamp(buf[i], -1f, 1f) * 32767);
            if (!w.Write(pcm.AsSpan(0, n))) throw new HearbyError("轉檔寫不進磁碟（可能已滿）");
            total += n;
            if (progress != null && reader.Length > 0)
            {
                double f = Math.Min(1, (double)reader.Position / reader.Length);
                if (f - lastFrac >= 0.01) { lastFrac = f; progress(f); }
            }
        }
        w.Close();
        return (double)total / WavIO.SampleRate;
    }
}

/// AIFF and AIFC with uncompressed samples — what Macs write (GarageBand, Logic, the `say` command, QuickTime): big-endian
/// integers ("NONE", "twos"), little-endian integers ("sowt"), 32-bit floats ("fl32"). NAudio's own reader only takes "NONE".
sealed class AiffReader : WaveStream
{
    readonly FileStream fs;
    readonly long dataStart, dataLength;
    readonly int bytesPerSample, block;
    readonly bool bigEndian, signed8;
    readonly WaveFormat format;
    long position;

    public AiffReader(string path)
    {
        fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            var b4 = new byte[4];
            string Id() { Fill(b4); return System.Text.Encoding.ASCII.GetString(b4); }
            uint U32() { Fill(b4); return (uint)(b4[0] << 24 | b4[1] << 16 | b4[2] << 8 | b4[3]); }
            int U16() { var b = new byte[2]; Fill(b); return b[0] << 8 | b[1]; }
            if (Id() != "FORM") throw new FormatException("not an AIFF file");
            U32();
            var form = Id();
            bool aifc = form == "AIFC";
            if (form != "AIFF" && !aifc) throw new FormatException("not an AIFF file");
            int channels = 0, bits = 0; double rate = 0; string comp = "NONE"; long ssnd = -1, ssndLen = 0;
            while (fs.Position + 8 <= fs.Length)
            {
                var id = Id();
                long len = U32();
                long next = fs.Position + len + (len & 1);
                if (id == "COMM")
                {
                    channels = U16(); U32(); bits = U16();
                    var ext = new byte[10]; Fill(ext); rate = Extended(ext);
                    if (aifc && len >= 22) comp = Id();
                }
                else if (id == "SSND")
                {
                    long offset = U32(); U32();
                    ssnd = fs.Position + offset;
                    ssndLen = Math.Max(0, len - 8 - offset);
                }
                fs.Position = Math.Min(next, fs.Length);
            }
            if (channels <= 0 || bits <= 0 || rate <= 0 || ssnd < 0) throw new FormatException("AIFF without sound data");
            bytesPerSample = (bits + 7) / 8;
            switch (comp)
            {
                case "NONE" or "twos": bigEndian = true; break;
                case "sowt": bigEndian = false; break;
                case "fl32" or "FL32": bigEndian = true; bytesPerSample = 4; bits = 32; break;
                default: throw new FormatException($"compressed AIFF ({comp}) is not supported");
            }
            bool isFloat = comp is "fl32" or "FL32";
            if (bytesPerSample is not (1 or 2 or 3 or 4)) throw new FormatException($"{bits}-bit AIFF is not supported");
            signed8 = bytesPerSample == 1;
            format = isFloat ? WaveFormat.CreateIeeeFloatWaveFormat((int)Math.Round(rate), channels) : new WaveFormat((int)Math.Round(rate), bytesPerSample * 8, channels);
            block = bytesPerSample * channels;
            dataStart = ssnd;
            dataLength = Math.Min(ssndLen, fs.Length - ssnd) / block * block;
            fs.Position = dataStart;
        }
        catch { fs.Dispose(); throw; }
    }

    void Fill(byte[] b)
    {
        int got = 0;
        while (got < b.Length) { int n = fs.Read(b, got, b.Length - got); if (n <= 0) throw new EndOfStreamException(); got += n; }
    }

    /// 80-bit IEEE 754 extended (the sample rate in COMM)
    static double Extended(byte[] e)
    {
        int exp = ((e[0] & 0x7F) << 8) | e[1];
        ulong mant = 0;
        for (int i = 2; i < 10; i++) mant = (mant << 8) | e[i];
        if (exp == 0 && mant == 0) return 0;
        double v = mant * Math.Pow(2, exp - 16383 - 63);
        return (e[0] & 0x80) != 0 ? -v : v;
    }

    public override WaveFormat WaveFormat => format;
    public override long Length => dataLength;
    public override long Position
    {
        get => position;
        set { position = Math.Clamp(value / block * block, 0, dataLength); fs.Position = dataStart + position; }
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        count = (int)Math.Min(count / block * block, dataLength - position);
        if (count <= 0) return 0;
        int got = 0;
        while (got < count) { int n = fs.Read(buffer, offset + got, count - got); if (n <= 0) break; got += n; }
        got = got / block * block;
        if (bigEndian && bytesPerSample > 1)
            for (int i = offset; i < offset + got; i += bytesPerSample) Array.Reverse(buffer, i, bytesPerSample);
        if (signed8)
            for (int i = offset; i < offset + got; i++) buffer[i] = (byte)(buffer[i] + 128);   // AIFF 8-bit is signed, WAV 8-bit unsigned
        position += got;
        return got;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) fs.Dispose();
        base.Dispose(disposing);
    }
}

