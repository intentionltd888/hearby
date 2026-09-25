// Config — config.json (schemaVersion 1): atomic writes, cached, thread-safe. Mirrors Store/Config.swift.
// Data contract: fields are only ever added; changing a meaning bumps schemaVersion with a migration.
// Unreadable/broken file = defaults (never blocks start-up); the broken file is kept as .broken-<time>.
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Hearby.Core;

public sealed class Config
{
    public const int CurrentSchema = 1;

    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; } = CurrentSchema;
    /// User data root; null = %USERPROFILE%\Hearby
    [JsonPropertyName("outputRoot")] public string? OutputRoot { get; set; }
    /// Second copy of every record; null = off
    [JsonPropertyName("mirrorDir")] public string? MirrorDir { get; set; }
    /// none (transcript only) / claude / endpoint (local model). "codex" is not offered on Windows (see ClaudeCli.cs)
    [JsonPropertyName("provider")] public string Provider { get; set; } = "none";
    /// system / light / dark
    [JsonPropertyName("appearance")] public string Appearance { get; set; } = "system";
    [JsonPropertyName("glossaryPath")] public string? GlossaryPath { get; set; }
    [JsonPropertyName("memoryEnabled")] public bool MemoryEnabled { get; set; }
    [JsonPropertyName("wizardDone")] public bool WizardDone { get; set; }
    [JsonPropertyName("wizardStep")] public int WizardStep { get; set; }
    [JsonPropertyName("scene")] public string Scene { get; set; } = "meeting";
    [JsonPropertyName("online")] public bool Online { get; set; }
    [JsonPropertyName("docCompany")] public string? DocCompany { get; set; }
    [JsonPropertyName("docRecorder")] public string? DocRecorder { get; set; }
    [JsonPropertyName("providerChosen")] public bool? ProviderChosen { get; set; }
    [JsonPropertyName("claudePath")] public string? ClaudePath { get; set; }
    [JsonPropertyName("claudeModel")] public string? ClaudeModel { get; set; }
    [JsonPropertyName("claudeEffort")] public string? ClaudeEffort { get; set; }
    [JsonPropertyName("codexPath")] public string? CodexPath { get; set; }
    [JsonPropertyName("codexModel")] public string? CodexModel { get; set; }
    /// Model download mirror (optional base URL)
    [JsonPropertyName("modelMirror")] public string? ModelMirror { get; set; }
    [JsonPropertyName("autoPDF")] public bool AutoPDF { get; set; }
    [JsonPropertyName("lastBrief")] public string? LastBrief { get; set; }
    /// Small status bar while recording with the panel closed; null = on
    [JsonPropertyName("floatingBar")] public bool? FloatingBar { get; set; }
    [JsonPropertyName("endpointURL")] public string? EndpointURL { get; set; }
    [JsonPropertyName("endpointModel")] public string? EndpointModel { get; set; }
    // ── added by the Windows version (fields only added) ──
    /// Speech model file name; null = the default for this platform (ModelCatalog)
    [JsonPropertyName("whisperModel")] public string? WhisperModel { get; set; }
    /// Transcribe on the GPU (Vulkan) when available; null = on
    [JsonPropertyName("useGPU")] public bool? UseGPU { get; set; }

    /// Look for new versions on GitHub in the background (Windows installer); null = on
    [JsonPropertyName("autoUpdate")] public bool? AutoUpdate { get; set; }

    [JsonIgnore] public bool FloatingBarOn => FloatingBar ?? true;
    [JsonIgnore] public bool AutoUpdateOn => AutoUpdate ?? true;
    [JsonIgnore] public bool UseGPUOn => UseGPU ?? true;

    public Config Clone() => (Config)MemberwiseClone();

    static readonly JsonSerializerOptions ReadOpts = new() { NumberHandling = JsonNumberHandling.Strict };

    public static Config Parse(string json)
    {
        var c = JsonSerializer.Deserialize<Config>(json, ReadOpts) ?? throw new JsonException("empty");
        c.Provider ??= "none"; c.Appearance ??= "system"; c.Scene ??= "meeting";
        return c;
    }

    /// Sorted keys, pretty-printed, nulls omitted (same shape as macOS JSONEncoder output)
    public string ToJson() => JsonUtil.SortedPretty(JsonSerializer.SerializeToNode(this, new JsonSerializerOptions { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull })!);
}

public sealed class ConfigStore
{
    public static readonly ConfigStore Shared = new();
    readonly object gate = new();
    Config? cache;

    public string Url => Path.Combine(Paths.Support, "config.json");

    public Config Current { get { lock (gate) { return cache ??= Load(); } } }

    public void Update(Action<Config> mutate)
    {
        lock (gate)
        {
            var c = (cache ?? Load()).Clone();
            mutate(c);
            Write(c);
            cache = c;
        }
    }

    /// Drop the cache (tests switch sandboxes)
    public void Reset() { lock (gate) { cache = null; } }

    Config Load()
    {
        var url = Url;
        if (!File.Exists(url)) return new Config();
        try
        {
            var c = Config.Parse(File.ReadAllText(url, Encoding.UTF8));
            if (c.SchemaVersion < Config.CurrentSchema) c.SchemaVersion = Config.CurrentSchema;
            return c;
        }
        catch (Exception e)
        {
            var stamp = DateTime.UtcNow.ToString("yyyy-MM-ddTHH-mm-ssZ", CultureInfo.InvariantCulture);
            try { File.Copy(url, url + ".broken-" + stamp, overwrite: false); } catch { }
            HearbyLog.Write($"config.json 讀不到，用預設值：{e.Message}");
            return new Config();
        }
    }

    void Write(Config c)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Url)!);
        var tmp = Path.Combine(Path.GetDirectoryName(Url)!, $".config.json.tmp-{Environment.ProcessId}");
        File.WriteAllText(tmp, c.ToJson(), new UTF8Encoding(false));
        File.Move(tmp, Url, overwrite: true);
    }
}

public static class JsonUtil
{
    public static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// String value of a node (null when missing or not a string)
    public static string? S(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    /// Recursively sort object keys (ordinal) and pretty-print
    public static string SortedPretty(JsonNode node) => Sort(node)!.ToJsonString(Pretty);

    public static JsonNode? Sort(JsonNode? n)
    {
        switch (n)
        {
            case JsonObject o:
                var s = new JsonObject();
                foreach (var kv in o.OrderBy(k => k.Key, StringComparer.Ordinal)) s[kv.Key] = Sort(kv.Value?.DeepClone());
                return s;
            case JsonArray a:
                var arr = new JsonArray();
                foreach (var x in a) arr.Add(Sort(x?.DeepClone()));
                return arr;
            default:
                return n?.DeepClone();
        }
    }
}
