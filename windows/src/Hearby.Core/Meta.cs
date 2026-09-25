// Meta — meta.json (MeetingMeta), prompt scenarios, segments, pause spans, the recording clock, mic health.
// Mirrors Speech/Transcript.swift (MeetingMeta, MeetingScenario, Segment), Audio/Pause.swift, Audio/MicWatch.swift.
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hearby.Core;

/// ISO-8601 dates like macOS JSONEncoder(.iso8601): "2026-09-20T06:30:00Z". Also reads the default Apple encoding
/// (seconds since 2001-01-01) that older meta.json files may contain.
public sealed class IsoDateConverter : JsonConverter<DateTimeOffset>
{
    static readonly DateTimeOffset AppleEpoch = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
    {
        if (r.TokenType == JsonTokenType.Number) return AppleEpoch.AddSeconds(r.GetDouble());
        var s = r.GetString() ?? throw new JsonException("date");
        return DateTimeOffset.Parse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
    }
    public override void Write(Utf8JsonWriter w, DateTimeOffset v, JsonSerializerOptions o) => w.WriteStringValue(Iso(v));
    public static string Iso(DateTimeOffset v) => v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
}

public sealed class NullableIsoDateConverter : JsonConverter<DateTimeOffset?>
{
    readonly IsoDateConverter inner = new();
    public override DateTimeOffset? Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => r.TokenType == JsonTokenType.Null ? null : inner.Read(ref r, typeof(DateTimeOffset), o);
    public override void Write(Utf8JsonWriter w, DateTimeOffset? v, JsonSerializerOptions o) { if (v is { } d) inner.Write(w, d, o); else w.WriteNullValue(); }
}

/// One pause: position in the recorded audio (seconds) + wall-clock start/end
public sealed class PauseSpan
{
    [JsonPropertyName("atSeconds")] public double AtSeconds { get; set; }
    [JsonPropertyName("began"), JsonConverter(typeof(IsoDateConverter))] public DateTimeOffset Began { get; set; }
    [JsonPropertyName("ended"), JsonConverter(typeof(NullableIsoDateConverter)), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public DateTimeOffset? Ended { get; set; }

    public PauseSpan() { }
    public PauseSpan(double atSeconds, DateTimeOffset began, DateTimeOffset? ended = null) { AtSeconds = atSeconds; Began = began; Ended = ended; }

    /// Seconds paused (null while still paused)
    [JsonIgnore] public double? Seconds => Ended is { } e ? Math.Max(0, (e - Began).TotalSeconds) : null;
    /// Position in the audio (ms). Slicing and the transcript marker both use this one integer
    [JsonIgnore] public int AtMs => (int)(Fmt.ClampSeconds(AtSeconds) * 1000);

    public const string MarkerPrefix = "（⏸ ";
    public static bool IsMarker(string line) => Str.TrimWS(line).Starts("（⏸");

    /// Mid pauses = something was recorded after them (a pause followed directly by stop does not count; nor one still open)
    public static List<PauseSpan> MidPauses(IEnumerable<PauseSpan> pauses, double totalSeconds) =>
        pauses.Where(p => p.Ended != null && p.AtSeconds < totalSeconds - 1).OrderBy(p => p.AtSeconds).ToList();

    /// 40 秒／12 分鐘／1 小時 5 分鐘
    public static string DurText(double seconds)
    {
        int t = (int)Math.Round(Fmt.ClampSeconds(seconds), MidpointRounding.AwayFromZero);
        if (t < 60) return $"{t} 秒";
        if (t < 3600) return $"{Math.Max(1, (int)Math.Round(t / 60.0, MidpointRounding.AwayFromZero))} 分鐘";
        int h = t / 3600, m = (t % 3600) / 60;
        return m == 0 ? $"{h} 小時" : $"{h} 小時 {m} 分鐘";
    }

    /// Wall clock HH:mm (Gregorian, 24h, in HearbyTime.Zone)
    public static string Clock(DateTimeOffset d) => HearbyTime.Local(d).ToString("HH:mm", CultureInfo.InvariantCulture);

    /// 「（⏸ 14:32–14:44 暫停了 12 分鐘，這段沒有錄）」
    [JsonIgnore]
    public string MarkerLine
    {
        get
        {
            var from = Clock(Began);
            var to = Ended is { } e ? Clock(e) : from;
            var when = from == to ? from : $"{from}–{to}";
            return $"{MarkerPrefix}{when} 暫停了 {DurText(Seconds ?? 0)}，這段沒有錄）";
        }
    }

    /// Insert pause markers into the transcript: lines sorted by time; a marker goes before the first line after the pause
    public static List<string> Weave(IReadOnlyList<(int FromMs, string Text)> lines, IEnumerable<PauseSpan> pauses, double totalSeconds)
    {
        var mids = MidPauses(pauses, totalSeconds);
        var outList = new List<string>(lines.Count + mids.Count);
        int k = 0;
        foreach (var l in lines)
        {
            while (k < mids.Count && l.FromMs >= mids[k].AtMs) { outList.Add(mids[k].MarkerLine); k++; }
            outList.Add(l.Text);
        }
        while (k < mids.Count) { outList.Add(mids[k].MarkerLine); k++; }
        return outList;
    }

    /// Header line of the record (null = no mid pauses)
    public static string? Note(IEnumerable<PauseSpan> pauses, double totalSeconds)
    {
        var mids = MidPauses(pauses, totalSeconds);
        if (mids.Count == 0) return null;
        var total = mids.Sum(p => p.Seconds ?? 0);
        return $"中途暫停 {mids.Count} 次，共 {DurText(total)}（暫停時沒有錄音，逐字稿裡標了位置）";
    }
}

/// Recording time accounting. Sleep while paused is not counted separately (that time is not recorded anyway)
public sealed class RecordingClock
{
    public DateTimeOffset StartedAt { get; private set; }
    public double SleepSeconds { get; private set; }
    public double PausedSeconds { get; private set; }
    public List<PauseSpan> Pauses { get; } = [];
    public bool SleptWhileRecording { get; private set; }
    DateTimeOffset? sleepBegan, pauseBegan;

    public RecordingClock(DateTimeOffset startedAt) { StartedAt = startedAt; }
    public bool IsPaused => pauseBegan != null;

    public double Recorded(DateTimeOffset now)
    {
        double sleeping = sleepBegan is { } s ? (now - s).TotalSeconds : 0;
        double pausing = pauseBegan is { } p ? (now - p).TotalSeconds : 0;
        return Math.Max(0, (now - StartedAt).TotalSeconds - SleepSeconds - sleeping - PausedSeconds - pausing);
    }

    public double CurrentPause(DateTimeOffset now) => pauseBegan is { } p ? Math.Max(0, (now - p).TotalSeconds) : 0;

    public bool Pause(DateTimeOffset now)
    {
        if (pauseBegan != null) return false;
        CloseSleep(now);
        Pauses.Add(new PauseSpan(Recorded(now), now));
        pauseBegan = now;
        return true;
    }

    public bool Resume(DateTimeOffset now)
    {
        if (pauseBegan is not { } b) return false;
        PausedSeconds += Math.Max(0, (now - b).TotalSeconds);
        pauseBegan = null;
        Pauses[^1].Ended = now;
        return true;
    }

    public bool NoteSleep(DateTimeOffset now)
    {
        if (sleepBegan != null || pauseBegan != null) return false;
        sleepBegan = now;
        return true;
    }

    /// true = a sleep that happened while recording just ended (tell the user that part has no sound)
    public bool NoteWake(DateTimeOffset now) => CloseSleep(now);

    public void Close(DateTimeOffset now) { CloseSleep(now); Resume(now); }

    bool CloseSleep(DateTimeOffset now)
    {
        if (sleepBegan is not { } b) return false;
        SleepSeconds += Math.Max(0, (now - b).TotalSeconds);
        sleepBegan = null;
        SleptWhileRecording = true;
        return true;
    }
}

/// Mic health: not paused yet almost silent for two minutes = probably the wrong mic or muted
public sealed class MicWatch
{
    public const double SilentSeconds = 120;
    public enum Event { Silent, Recovered }
    public DateTimeOffset LastHeard { get; private set; }
    public bool Alerting { get; private set; }
    public MicWatch(DateTimeOffset now) { LastHeard = now; }
    public void Reset(DateTimeOffset now) => LastHeard = now;
    public Event? Update(float level, DateTimeOffset now)
    {
        if (level >= Pipeline.Silence)
        {
            LastHeard = now;
            if (Alerting) { Alerting = false; return Event.Recovered; }
            return null;
        }
        if (!Alerting && (now - LastHeard).TotalSeconds >= SilentSeconds) { Alerting = true; return Event.Silent; }
        return null;
    }
}

/// Prompt scenario (tracks ≠ people: the channel is a fact, who is on it depends on the scenario)
public enum MeetingScenario { Onsite, OnlineHeadphones, OnlineSpeaker, PhoneSpeaker }

public static class MeetingScenarioExt
{
    public static readonly MeetingScenario[] All = [MeetingScenario.Onsite, MeetingScenario.OnlineHeadphones, MeetingScenario.OnlineSpeaker, MeetingScenario.PhoneSpeaker];
    public static string Raw(this MeetingScenario s) => s switch
    {
        MeetingScenario.Onsite => "onsite", MeetingScenario.OnlineHeadphones => "online_headphones",
        MeetingScenario.OnlineSpeaker => "online_speaker", _ => "phone_speaker",
    };
    public static MeetingScenario? FromRaw(string? raw) => raw switch
    {
        "onsite" => MeetingScenario.Onsite, "online_headphones" => MeetingScenario.OnlineHeadphones,
        "online_speaker" => MeetingScenario.OnlineSpeaker, "phone_speaker" => MeetingScenario.PhoneSpeaker, _ => null,
    };
    public static string DisplayName(this MeetingScenario s) => s switch
    {
        MeetingScenario.Onsite => "只有現場人", MeetingScenario.OnlineHeadphones => "線上・戴耳機",
        MeetingScenario.OnlineSpeaker => "線上・開喇叭", _ => "電話擴音",
    };
    public static string MicWho(this MeetingScenario s) => s is MeetingScenario.Onsite or MeetingScenario.PhoneSpeaker ? "現場" : "我方";
}

public sealed record Segment(int FromMs, int ToMs, string Text, string Who);

public sealed class MeetingMeta
{
    [JsonPropertyName("schemaVersion")] public int? SchemaVersion { get; set; } = 1;
    [JsonPropertyName("id")] public string? Id { get; set; }
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("attendees")] public string Attendees { get; set; } = "";
    [JsonPropertyName("started"), JsonConverter(typeof(IsoDateConverter))] public DateTimeOffset Started { get; set; } = DateTimeOffset.Now;
    [JsonPropertyName("seconds")] public double Seconds { get; set; }
    [JsonPropertyName("micMax")] public float MicMax { get; set; }
    [JsonPropertyName("sysMax")] public float SysMax { get; set; }
    [JsonPropertyName("warnings")] public List<string> Warnings { get; set; } = [];
    [JsonPropertyName("scene")] public string? Scene { get; set; }
    [JsonPropertyName("source")] public string? Source { get; set; }
    [JsonPropertyName("scenario")] public string? Scenario { get; set; }
    [JsonPropertyName("onsiteCount")] public int? OnsiteCount { get; set; }
    [JsonPropertyName("brief")] public List<string>? Brief { get; set; }
    [JsonPropertyName("imported")] public bool? Imported { get; set; }
    [JsonPropertyName("sourceFile")] public string? SourceFile { get; set; }
    [JsonPropertyName("provider")] public string? Provider { get; set; }
    [JsonPropertyName("outName")] public string? OutName { get; set; }
    [JsonPropertyName("versions")] public List<string>? Versions { get; set; }
    [JsonPropertyName("pauses")] public List<PauseSpan>? Pauses { get; set; }

    static readonly JsonSerializerOptions Opts = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
    };

    public static MeetingMeta? Load(string dir)
    {
        var f = Path.Combine(dir, "meta.json");
        try { return File.Exists(f) ? JsonSerializer.Deserialize<MeetingMeta>(File.ReadAllText(f, Encoding.UTF8), Opts) : null; }
        catch (Exception e) { HearbyLog.Write($"meta.json 讀不到（{dir}）：{e.Message}"); return null; }
    }

    public static void Save(MeetingMeta m, string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            var json = JsonUtil.SortedPretty(JsonSerializer.SerializeToNode(m, Opts)!);
            var tmp = Path.Combine(dir, ".meta.json.tmp");
            File.WriteAllText(tmp, json, new UTF8Encoding(false));
            File.Move(tmp, Path.Combine(dir, "meta.json"), overwrite: true);
        }
        catch (Exception e) { HearbyLog.Write($"meta.json 寫不進去：{e.Message}"); }
    }
}
