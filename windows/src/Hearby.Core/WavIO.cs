// WavIO — crash-safe WAV writer + slice reading (mirrors Audio/WavIO.swift)
//
// Standard 44-byte header; the length fields are patched every 5 seconds of audio, so a crash, a kill or a power cut
// loses at most the last 5 s of *length information* (the samples are on disk; RepairHeader fixes it up to the end).
// Slices are read straight from the PCM byte range with their own clean header — the source header is never trusted.
using System.Buffers.Binary;

namespace Hearby.Core;

public static class WavIO
{
    public const int SampleRate = 16000;
    public const int BytesPerSecond = 32000; // 16 kHz × mono × s16

    public static byte[] Header(ulong dataBytes)
    {
        var d = new byte[44];
        "RIFF"u8.CopyTo(d.AsSpan(0));
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(4), unchecked((uint)(36 + dataBytes)));
        "WAVE"u8.CopyTo(d.AsSpan(8));
        "fmt "u8.CopyTo(d.AsSpan(12));
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(16), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(20), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(22), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(24), SampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(28), BytesPerSecond);
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(32), 2);
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(34), 16);
        "data"u8.CopyTo(d.AsSpan(36));
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(40), unchecked((uint)dataBytes));
        return d;
    }

    static int IndexOfData(ReadOnlySpan<byte> head) => head.IndexOf("data"u8);

    /// PCM range (start, bytes). Length is always "end of file − start", never the header field
    public static (long Start, long Bytes)? PcmRange(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            long size = fs.Length;
            if (size <= 44) return null;
            var head = new byte[Math.Min(8192, size)];
            int n = fs.Read(head, 0, head.Length);
            int r = IndexOfData(head.AsSpan(0, n));
            if (r < 0) return null;
            long start = r + 8;
            if (size <= start) return null;
            return (start, (size - start) & ~1L);
        }
        catch { return null; }
    }

    public static int? DurationMs(string path) => PcmRange(path) is { } r ? (int)(r.Bytes * 1000 / BytesPerSecond) : null;

    static long MsToBytes(long ms, long cap) => Math.Min(cap, (Math.Max(0, ms) * BytesPerSecond / 1000) & ~1L);

    public static short[] ReadPcm(string path, int fromMs, int toMs)
    {
        if (toMs <= fromMs || PcmRange(path) is not { } r) return [];
        long a = MsToBytes(fromMs, r.Bytes), b = MsToBytes(toMs, r.Bytes);
        if (b <= a) return [];
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            fs.Seek(r.Start + a, SeekOrigin.Begin);
            var buf = new byte[b - a];
            int got = 0;
            while (got < buf.Length) { int k = fs.Read(buf, got, buf.Length - got); if (k <= 0) break; got += k; }
            var outArr = new short[got / 2];
            Buffer.BlockCopy(buf, 0, outArr, 0, outArr.Length * 2);
            return outArr;
        }
        catch { return []; }
    }

    /// One level per 100 ms, same scale as the recording meters (÷32768, RMS×4, capped at 1). Single-precision like Swift
    public static float[] BlockLevels(short[] pcm, int blockMs = 100)
    {
        int n = Math.Max(1, SampleRate * blockMs / 1000);
        var outList = new List<float>(pcm.Length / n + 1);
        int i = 0;
        while (i < pcm.Length)
        {
            int e = Math.Min(pcm.Length, i + n);
            float sum = 0;
            for (int k = i; k < e; k++) { float v = pcm[k] / 32768f; sum += v * v; }
            outList.Add(MathF.Min(1f, MathF.Sqrt(sum / (e - i)) * 4f));
            i = e;
        }
        return [.. outList];
    }

    /// RMS level of s16 samples (0…1, ×4, capped)
    public static float Level(ReadOnlySpan<short> pcm)
    {
        if (pcm.Length == 0) return 0;
        float sum = 0;
        foreach (var s in pcm) { float f = s / 32768f; sum += f * f; }
        return MathF.Min(1f, MathF.Sqrt(sum / pcm.Length) * 4f);
    }

    public static bool WriteSlice(string src, int fromMs, int toMs, string dst)
    {
        if (toMs <= fromMs || PcmRange(src) is not { } r) return false;
        long a = MsToBytes(fromMs, r.Bytes), b = MsToBytes(toMs, r.Bytes);
        if (b <= a) return false;
        try
        {
            using var inFs = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var outFs = new FileStream(dst, FileMode.Create, FileAccess.Write);
            outFs.Write(Header((ulong)(b - a)));
            inFs.Seek(r.Start + a, SeekOrigin.Begin);
            long left = b - a;
            var buf = new byte[4 * 1024 * 1024];
            while (left > 0)
            {
                int k = inFs.Read(buf, 0, (int)Math.Min(buf.Length, left));
                if (k <= 0) return false;
                outFs.Write(buf, 0, k);
                left -= k;
            }
            return true;
        }
        catch { return false; }
    }

    /// Multiply by a gain and write (quiet slices are boosted before transcribing); clipped to ±32767, never wraps
    public static bool WritePcm(short[] pcm, float gain, string dst)
    {
        if (pcm.Length == 0) return false;
        try
        {
            var bytes = new byte[44 + pcm.Length * 2];
            Header((ulong)(pcm.Length * 2)).CopyTo(bytes, 0);
            for (int i = 0; i < pcm.Length; i++)
            {
                float v = MathF.Round(pcm[i] * gain, MidpointRounding.AwayFromZero);
                short s = (short)Math.Max(-32767f, Math.Min(32767f, v));
                BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(44 + i * 2), s);
            }
            File.WriteAllBytes(dst, bytes);
            return true;
        }
        catch { return false; }
    }

    public static void WritePcmFile(string dst, ReadOnlySpan<short> pcm)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
        using var fs = new FileStream(dst, FileMode.Create, FileAccess.Write);
        fs.Write(Header((ulong)(pcm.Length * 2)));
        fs.Write(System.Runtime.InteropServices.MemoryMarshal.AsBytes(pcm));
    }

    /// Crash recovery: fix the length fields from the real file size
    public static void RepairHeader(string path)
    {
        try
        {
            if (!File.Exists(path)) return;
            using var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
            long size = fs.Length;
            if (size <= 44) return;
            var b4 = new byte[4];
            BinaryPrimitives.WriteUInt32LittleEndian(b4, unchecked((uint)(size - 8)));
            fs.Seek(4, SeekOrigin.Begin); fs.Write(b4);
            fs.Seek(0, SeekOrigin.Begin);
            var head = new byte[Math.Min(8192, size)];
            int n = fs.Read(head, 0, head.Length);
            int r = IndexOfData(head.AsSpan(0, n));
            if (r >= 0)
            {
                BinaryPrimitives.WriteUInt32LittleEndian(b4, unchecked((uint)(size - r - 8)));
                fs.Seek(r + 4, SeekOrigin.Begin); fs.Write(b4);
            }
        }
        catch { }
    }

    public static double? Seconds(string path) => DurationMs(path) is { } ms ? ms / 1000.0 : null;
}

/// Crash-safe WAV writer (16 kHz mono s16). Single writer thread.
public sealed class CrashSafeWavWriter : IDisposable
{
    public string Path { get; }
    readonly FileStream fs;
    public ulong DataBytes { get; private set; }
    ulong sinceHeader;
    const ulong HeaderEvery = WavIO.BytesPerSecond * 5;
    bool closed;

    public CrashSafeWavWriter(string path)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        // Same-second re-record: keep the existing file aside, both survive
        if (File.Exists(path))
        {
            var aside = System.IO.Path.ChangeExtension(path, $"prev-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}.wav");
            try { File.Move(path, aside); } catch { }
        }
        fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        fs.Write(WavIO.Header(0));
        fs.Flush(true);
        Path = path;
    }

    public bool Write(ReadOnlySpan<short> samples)
    {
        if (samples.IsEmpty || closed) return true;
        try
        {
            fs.Write(System.Runtime.InteropServices.MemoryMarshal.AsBytes(samples));
            ulong n = (ulong)samples.Length * 2;
            DataBytes += n; sinceHeader += n;
            if (sinceHeader >= HeaderEvery) { sinceHeader = 0; PatchHeader(); }
            return true;
        }
        catch { return false; }
    }

    void PatchHeader()
    {
        try
        {
            var b4 = new byte[4];
            long end = fs.Position;
            BinaryPrimitives.WriteUInt32LittleEndian(b4, unchecked((uint)(36 + DataBytes)));
            fs.Seek(4, SeekOrigin.Begin); fs.Write(b4);
            BinaryPrimitives.WriteUInt32LittleEndian(b4, unchecked((uint)DataBytes));
            fs.Seek(40, SeekOrigin.Begin); fs.Write(b4);
            fs.Flush(true);
            fs.Seek(end, SeekOrigin.Begin);
        }
        catch { try { fs.Seek(0, SeekOrigin.End); } catch { } }
    }

    public void Close()
    {
        if (closed) return;
        closed = true;
        PatchHeader();
        try { fs.Dispose(); } catch { }
    }

    public void Dispose() => Close();
}
