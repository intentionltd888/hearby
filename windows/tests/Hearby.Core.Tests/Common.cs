// Test plumbing: fixture loading, a sandbox per test (never touches real folders), pinned time zone.
using System.Text.Json.Nodes;
using Hearby.Core;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Hearby.Core.Tests;

public static class Fixture
{
    static string? dir;
    public static string Dir
    {
        get
        {
            if (dir != null) return dir;
            var d = new DirectoryInfo(AppContext.BaseDirectory);
            while (d != null && !Directory.Exists(Path.Combine(d.FullName, "contract", "fixtures"))) d = d.Parent;
            return dir = d == null ? throw new Exception("contract/fixtures not found above " + AppContext.BaseDirectory) : Path.Combine(d.FullName, "contract", "fixtures");
        }
    }

    public static JsonArray Cases(string name)
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(Dir, name + ".json")))!.AsObject();
        Assert.Equal(1, (int)root["contract"]!);
        return root["cases"]!.AsArray();
    }

    public static string S(JsonNode? n) => n!.GetValue<string>();
    public static string? SN(JsonNode? n) => n is null ? null : n.GetValue<string>();
    public static int I(JsonNode? n) => n is JsonValue v && v.TryGetValue<int>(out var i) ? i : (int)n!.GetValue<double>();
    public static int? IN(JsonNode? n) => n is null ? null : I(n);
    public static double D(JsonNode? n) => n is JsonValue v && v.TryGetValue<int>(out var i) ? i : n!.GetValue<double>();
    public static bool B(JsonNode? n) => n!.GetValue<bool>();
    public static List<string> SL(JsonNode? n) => n!.AsArray().Select(x => x!.GetValue<string>()).ToList();
    public static List<(int, int)> Pairs(JsonNode? n) => n!.AsArray().Select(x => (I(x![0]), I(x[1]))).ToList();
}

/// Sandbox: HEARBY_OUTPUT_ROOT / SUPPORT_DIR / LOG_DIR under the temp folder; Asia/Taipei like the fixture run
public sealed class Sandbox : IDisposable
{
    public string Box { get; }
    public static readonly TimeZoneInfo Taipei = FindTaipei();

    static TimeZoneInfo FindTaipei()
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById("Asia/Taipei"); }
        catch { return TimeZoneInfo.FindSystemTimeZoneById("Taipei Standard Time"); }
    }

    public Sandbox()
    {
        Box = Path.Combine(Path.GetTempPath(), "hearby-cs-" + Guid.NewGuid().ToString("N"));
        Environment.SetEnvironmentVariable("HEARBY_OUTPUT_ROOT", Path.Combine(Box, "root"));
        Environment.SetEnvironmentVariable("HEARBY_SUPPORT_DIR", Path.Combine(Box, "support"));
        Environment.SetEnvironmentVariable("HEARBY_LOG_DIR", Path.Combine(Box, "logs"));
        ConfigStore.Shared.Reset();
        Paths.Ensure();
        HearbyTime.Zone = Taipei;
        Clean.Converter = new IdentityConverter();
    }

    public void Dispose()
    {
        foreach (var k in new[] { "HEARBY_OUTPUT_ROOT", "HEARBY_SUPPORT_DIR", "HEARBY_LOG_DIR" }) Environment.SetEnvironmentVariable(k, null);
        ConfigStore.Shared.Reset();
        try { if (Box.StartsWith(Path.GetTempPath(), StringComparison.Ordinal)) Directory.Delete(Box, true); } catch { }
    }

    // ── synthetic audio, the same integer square wave the Swift fixture generator used ──

    public static short[] Synth(JsonArray spec)
    {
        var outList = new List<short>();
        foreach (var seg in spec)
        {
            int n = Fixture.I(seg![0]) * 16000, amp = Fixture.I(seg[1]);
            for (int i = 0; i < n; i++) outList.Add((short)(amp == 0 ? 0 : ((i / 16) % 2 == 0 ? amp : -amp)));
        }
        return [.. outList];
    }

    public static short[] Bursty(int amp)
    {
        var p = new short[16000 * 10];
        for (int i = 0; i < p.Length; i++) if ((i / 16000) % 3 != 0) p[i] = (short)((i / 16) % 2 == 0 ? amp : -amp);
        return p;
    }
}

/// Fake provider: records what it was given, returns a fixed reply (null = error)
public sealed class FakeProvider(string id, string? reply, string? err) : IProvider
{
    public string? SeenSystem, SeenUser;
    public string Id => id;
    public string DisplayName => "假的整理";
    public int ContextBudget => 100_000;
    public int MaxOutputTokens => 8000;
    public TrustLevel Trust => TrustLevel.Local;
    public ProviderStatus Check() => new(ProviderStatus.Levels.Ready, "ok");
    public (string?, string?) Complete(string system, string user)
    {
        SeenSystem = system; SeenUser = user;
        return (reply, reply == null ? (err ?? "假的錯誤") : null);
    }
}
