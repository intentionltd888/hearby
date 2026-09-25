// Doctor — seven checks in one place (CLI --doctor and the Settings "is everything OK" page). Mirrors Doctor.swift.
// ① system ② microphone ③ system audio ④ speech model ⑤ how records are written ⑥ disk ⑦ folder.
// One line each: ok / warn / missing / unknown + one plain sentence. Windows-specific checks come from IDoctorPlatform.
namespace Hearby.Core;

public sealed record DoctorItem(string Name, DoctorItem.Status State, string Detail)
{
    public enum Status { Ok, Warn, Missing, Unknown }
}

public sealed record DoctorReport(List<DoctorItem> Items)
{
    public bool AllOK => Items.All(i => i.State == DoctorItem.Status.Ok);
    public string Text
    {
        get
        {
            var o = new System.Text.StringBuilder("Hearby doctor\n");
            foreach (var i in Items)
            {
                var tag = i.State switch { DoctorItem.Status.Ok => "  ok  ", DoctorItem.Status.Warn => "  警  ", DoctorItem.Status.Missing => "  缺  ", _ => "  ？  " };
                o.Append($"{tag} {i.Name}：{i.Detail}\n");
            }
            return o.ToString();
        }
    }
}

public interface IDoctorPlatform
{
    DoctorItem System();
    DoctorItem Microphone();
    DoctorItem SystemAudio();
}

public static class Doctor
{
    public static IDoctorPlatform? PlatformChecks { get; set; }

    public static DoctorReport Run(bool deep = false) => new(
    [
        PlatformChecks?.System() ?? new DoctorItem("系統", DoctorItem.Status.Unknown, "查不到"),
        PlatformChecks?.Microphone() ?? new DoctorItem("麥克風", DoctorItem.Status.Unknown, "查不到"),
        PlatformChecks?.SystemAudio() ?? new DoctorItem("系統聲", DoctorItem.Status.Unknown, "查不到"),
        Model(), Provider(deep), Disk(), Folder(),
    ]);

    static string Gb(double bytes) => (bytes / 1_073_741_824).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);

    public static DoctorItem Model()
    {
        if (Transcriber.Engine is not { Available: true }) return new("聽打模型", DoctorItem.Status.Missing, "聽打引擎遺失——請重新安裝 Hearby");
        if (ModelCatalog.InstalledModel() is { } m)
        {
            long size = 0; try { size = new FileInfo(m).Length; } catch { }
            if (ModelCatalog.SpecFor(Path.GetFileName(m)) is { } spec && spec.Bytes > 0 && size != spec.Bytes)
                return new("聽打模型", DoctorItem.Status.Warn, $"檔案大小不對（{Gb(size)} GB，應該是 {Gb(spec.Bytes)} GB）——可能沒下載完。把它移走後重開 Hearby 會重新下載：{m}");
            return new("聽打模型", DoctorItem.Status.Ok, $"已在（{Gb(size)} GB）{Path.GetDirectoryName(m)}");
        }
        return new("聽打模型", DoctorItem.Status.Missing, $"還沒下載（{Gb(ModelCatalog.Default.Bytes)} GB）——設定精靈第一頁按「開始設定」就會在背景下載");
    }

    public static DoctorItem Provider(bool deep)
    {
        var p = Providers.Current();
        if (p.Id == "none") return new("整理方式", DoctorItem.Status.Ok, "只要逐字稿（不用帳號）");
        if (p.Id == "endpoint" && !deep)
        {
            if (LocalEndpoint.UrlProblem(LocalEndpoint.BaseUrl) is { } bad) return new("整理方式", DoctorItem.Status.Missing, $"{p.DisplayName}：{bad}");
            return new("整理方式", DoctorItem.Status.Ok, $"{p.DisplayName}（{LocalEndpoint.BaseUrl}，模型 {LocalEndpoint.Model ?? "還沒選"}）；連不連得上加 --deep 才查");
        }
        if (!deep)
        {
            if (ClaudeCli.BinaryPath() is not { } b) return new("整理方式", DoctorItem.Status.Missing, $"{p.DisplayName}：還沒裝——設定頁那列按「安裝」");
            return new("整理方式", DoctorItem.Status.Ok, $"{p.DisplayName}（{b}）；登入狀態加 --deep 才查");
        }
        var st = p.Check();
        return st.Level == ProviderStatus.Levels.Ready
            ? new("整理方式", DoctorItem.Status.Ok, $"{p.DisplayName}：{st.Text}")
            : new("整理方式", DoctorItem.Status.Missing, $"{p.DisplayName}：{st.Text}");
    }

    public static DoctorItem Disk()
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(Paths.Home))!;
            double gb = new DriveInfo(root).AvailableFreeSpace / 1_073_741_824.0;
            var g = gb.ToString(gb < 10 ? "0.0" : "0", System.Globalization.CultureInfo.InvariantCulture);
            if (gb < 3) return new("磁碟", DoctorItem.Status.Missing, $"只剩 {g} GB——模型加錄音放不下");
            if (gb < 10) return new("磁碟", DoctorItem.Status.Warn, $"剩 {g} GB");
            return new("磁碟", DoctorItem.Status.Ok, $"剩 {g} GB");
        }
        catch (Exception e) { return new("磁碟", DoctorItem.Status.Unknown, e.Message); }
    }

    public static DoctorItem Folder()
    {
        var r = Paths.Root;
        if (Paths.IsWritable(r))
        {
            var d = r;
            if (!Directory.Exists(r)) d += "（第一次啟動會建立）";
            if (Paths.Mirror is { } m) d += $"（副本→{m}）";
            return new("資料夾", DoctorItem.Status.Ok, d);
        }
        return new("資料夾", DoctorItem.Status.Missing, $"{r} 寫不進去");
    }
}
