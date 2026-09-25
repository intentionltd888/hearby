// ProvidersPane — who writes the record (mirrors ProvidersPane in MainWindow.swift): my Claude / a local model (settings
// only) / transcript only. Each row: the choice, name, status, main action. Status is re-checked every 3 s in the background.
// ChatGPT (Codex CLI) is not offered on Windows yet (see Providers.cs: it has no sandbox there).
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Hearby.Core;

namespace Hearby.App.UI;

public sealed class ProvidersPane : ContentControl
{
    readonly bool compact, showEndpoint;
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(3) };
    Dictionary<string, ProviderStatus> status = [];
    string selected = ConfigStore.Shared.Current.Provider;
    bool refreshing;
    string code = "";
    EndpointForm? endpointForm;

    public ProvidersPane(bool compact = false, bool showEndpoint = true)
    {
        this.compact = compact;
        this.showEndpoint = showEndpoint;
        tick.Tick += (_, _) => Refresh();
        Loaded += (_, _) => { Refresh(); tick.Start(); ClaudeInstall.Shared.Changed += Build; ClaudeLogin.Shared.Changed += Build; };
        Unloaded += (_, _) => { tick.Stop(); ClaudeInstall.Shared.Changed -= Build; ClaudeLogin.Shared.Changed -= Build; };
        Build();
    }

    void Build()
    {
        var p = new StackPanel();
        p.Children.Add(Row("claude", "交給我的 Claude 整理", "要有 Claude 的付費帳號（Pro 或 Max）。按下去會幫你裝好 Claude Code、開瀏覽器登入。用的是帳號本來就有的額度，不另外收費。"));
        if (showEndpoint)
        {
            p.Children.Add(Row("endpoint", "交給本機模型整理（Ollama／LM Studio）", "不用帳號、內容不離開這台電腦：用你自己裝的模型，建議 16 GB 以上記憶體。整理得比 Claude 簡略，決議與待辦請自己再看一次。"));
            if (selected == "endpoint") p.Children.Add(endpointForm ??= new EndpointForm(Refresh));
        }
        p.Children.Add(Row("none", "先只要逐字稿", "不用任何帳號。有誰講了什麼、幾分幾秒；之後想改隨時可以。"));
        if (FlowLine() is { } f) p.Children.Add(f);
        Content = p;
    }

    FrameworkElement Row(string id, string title, string sub)
    {
        var st = status.GetValueOrDefault(id) ?? new ProviderStatus(ProviderStatus.Levels.Pending, "檢查中…");
        bool on = selected == id;
        var dot = new Grid { Width = 18, Height = 18, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
        dot.Children.Add(new Ellipse { Stroke = on ? Theme.InkStrong : Theme.InkSoft, StrokeThickness = 1.2 });
        if (on) dot.Children.Add(new Ellipse { Width = 9, Height = 9, Fill = Theme.InkStrong });
        var text = new StackPanel { Margin = new Thickness(Neu.MD, 0, 0, 0) };
        text.Children.Add(Neu.Text(title, Neu.TBody, Theme.InkStrong, semi: on));
        text.Children.Add(Neu.Text(sub, Neu.TMicro, Theme.InkMid));
        var tag = Neu.StatusTag(Level(st.Level), st.Text);
        FrameworkElement? action = st.Action is { } a ? Neu.Chip(a, () => Perform(id, st)) : null;
        FrameworkElement body;
        if (compact)
        {
            var s = new StackPanel();
            var top = new DockPanel { LastChildFill = true };
            DockPanel.SetDock(dot, Dock.Left);
            top.Children.Add(dot);
            top.Children.Add(text);
            s.Children.Add(top);
            var bottom = new DockPanel { LastChildFill = true, Margin = new Thickness(18 + Neu.MD, Neu.SM, 0, 0) };
            if (action != null) { DockPanel.SetDock(action, Dock.Right); bottom.Children.Add(action); }
            tag.VerticalAlignment = VerticalAlignment.Center;
            bottom.Children.Add(tag);
            s.Children.Add(bottom);
            body = s;
        }
        else
        {
            var d = new DockPanel { LastChildFill = true };
            DockPanel.SetDock(dot, Dock.Left);
            d.Children.Add(dot);
            var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            tag.Width = 210; tag.VerticalAlignment = VerticalAlignment.Center;
            right.Children.Add(tag);
            var slot = new Border { Width = 116, Child = action };
            right.Children.Add(slot);
            DockPanel.SetDock(right, Dock.Right);
            d.Children.Add(right);
            d.Children.Add(text);
            body = d;
        }
        FrameworkElement surface;
        var pad = new Thickness(Neu.LG, Neu.MD, Neu.LG, Neu.MD);
        if (on) surface = Neu.Inset(body, Neu.RCard, 0.9, pad);
        else { var (v, _) = Neu.Raised(body, Neu.RCard, 0.5, pad); surface = v; }
        var b = new PressButton { Content = surface, Margin = new Thickness(0, 0, 0, Neu.SM) };
        System.Windows.Automation.AutomationProperties.SetName(b, title);
        b.Click += (_, _) => Select(id);
        return b;
    }

    static Neu.Level Level(ProviderStatus.Levels l) => l switch { ProviderStatus.Levels.Ready => Neu.Level.Ready, ProviderStatus.Levels.Pending => Neu.Level.Pending, _ => Neu.Level.Missing };

    void Select(string id)
    {
        selected = id;
        Providers.Select(id);
        if (status.GetValueOrDefault(id) is { } st && st.Level != ProviderStatus.Levels.Ready && id == "claude") Perform(id, st);
        Build();
        Refresh();
        AppState.Shared.RefreshIdle();
    }

    void Perform(string id, ProviderStatus st)
    {
        if (id != "claude") return;
        if (st.Level == ProviderStatus.Levels.Missing)
        {
            if (!ClaudeInstall.Shared.Start()) Gui.Toast("安裝程式開不起來：到 claude.com 下載 Claude Code 自己裝，裝好回來按「重新檢查」");
        }
        else if (st.Level == ProviderStatus.Levels.Pending)
        {
            ClaudeCli.ResetAuthCache();
            ClaudeLogin.Shared.Start();
        }
    }

    FrameworkElement? FlowLine()
    {
        var ci = ClaudeInstall.Shared; var cl = ClaudeLogin.Shared;
        string? line = ci.Running || ci.Failed ? ci.Note : cl.Running || cl.Note.Length > 0 ? cl.Note : null;
        if (line == null) return null;
        var p = new StackPanel();
        p.Children.Add(Neu.Text(line, Neu.TBody, Theme.InkStrong));
        if (ci.Running) { var g = Neu.Groove(null, 10); g.Margin = new Thickness(0, Neu.SM, 0, 0); p.Children.Add(g); }
        var row = new WrapPanel { Margin = new Thickness(0, Neu.SM, 0, 0) };
        if (cl.Running && cl.NeedsCode)
        {
            var (field, box) = Neu.Field("貼上網頁給的代碼", code, t => code = t);
            field.Width = 220; field.Margin = new Thickness(0, 3, Neu.SM, 0);
            row.Children.Add(field);
            row.Children.Add(Neu.Chip("送出", () => cl.Submit(box.Text)));
        }
        if (cl.Running && cl.Url != null) row.Children.Add(Neu.Chip("瀏覽器沒開？再開一次", cl.OpenBrowserAgain));
        if (ci.Running) row.Children.Add(Neu.Chip("取消", ci.Cancel));
        if (cl.Running) row.Children.Add(Neu.Chip("取消", cl.Cancel));
        if (!ci.Running && !cl.Running) row.Children.Add(Neu.Chip("重新檢查", () => { ClaudeCli.ResetAuthCache(); Refresh(); }));
        p.Children.Add(row);
        var inset = Neu.Inset(p, Neu.RCard, 0.7, new Thickness(Neu.MD));
        inset.Margin = new Thickness(0, Neu.XS, 0, 0);
        return inset;
    }

    void Refresh()
    {
        if (refreshing) return;
        refreshing = true;
        bool wantEndpoint = showEndpoint && selected == "endpoint";
        Task.Run(() =>
        {
            var s = new Dictionary<string, ProviderStatus>();
            foreach (var p in Providers.All.Where(p => p.Id != "endpoint" || wantEndpoint))
            {
                try { s[p.Id] = p.Check(); } catch (Exception e) { s[p.Id] = new ProviderStatus(ProviderStatus.Levels.Pending, e.Message); }
            }
            s.TryAdd("endpoint", new ProviderStatus(ProviderStatus.Levels.Pending, "點一下設定位址與模型"));
            var cur = ConfigStore.Shared.Current.Provider;
            Gui.OnUi(() =>
            {
                refreshing = false;
                bool changed = cur != selected || !SameStatus(s);
                status = s;
                if (cur != selected) selected = cur;
                if (changed) Build();
            });
        });
    }

    bool SameStatus(Dictionary<string, ProviderStatus> s) =>
        s.Count == status.Count && s.All(kv => status.TryGetValue(kv.Key, out var o) && o == kv.Value);
}

/// Local model: address + the models read from it + save. A line on how to install it for people who have not
public sealed class EndpointForm : ContentControl
{
    readonly Action onSaved;
    string url = ConfigStore.Shared.Current.EndpointURL ?? LocalEndpoint.DefaultUrl;
    string model = ConfigStore.Shared.Current.EndpointModel ?? "";
    List<string> models = [];
    string msg = "";
    bool loading;

    public EndpointForm(Action onSaved)
    {
        this.onSaved = onSaved;
        Margin = new Thickness(Neu.LG, 0, Neu.LG, Neu.SM);
        Loaded += (_, _) => Load();
        Build();
    }

    static string Hint
    {
        get
        {
            var t = $"還沒裝的話：到 ollama.com 下載 Ollama，裝好後在「命令提示字元」打「ollama pull {LocalEndpoint.SuggestedModel}」（約 2.5 GB），回來按「讀取模型」。";
            if (LocalEndpoint.MemoryIsTight) t += "這台電腦的記憶體不到 16 GB：本機模型會跑得很慢，開會時最好不要讓它同時整理。";
            return t;
        }
    }

    void Build()
    {
        var p = new StackPanel();
        var r1 = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.SM) };
        var read = Neu.Chip(loading ? "讀取中…" : "讀取模型", Load, Neu.IcRefresh, !loading);
        DockPanel.SetDock(read, Dock.Right);
        r1.Children.Add(read);
        var (uf, _) = Neu.Field("位址（Ollama：http://127.0.0.1:11434；LM Studio：http://127.0.0.1:1234）", url, t => url = t);
        uf.Margin = new Thickness(0, 3, Neu.SM, 0);
        r1.Children.Add(uf);
        p.Children.Add(r1);
        var r2 = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, Neu.SM) };
        var save = Neu.Chip("存", Save, enabled: model.Length > 0);
        DockPanel.SetDock(save, Dock.Right);
        r2.Children.Add(save);
        var combo = new ComboBox
        {
            ItemsSource = models, SelectedItem = models.Contains(model) ? model : null, IsEnabled = models.Count > 0,
            FontFamily = Neu.UIFont, FontSize = Neu.TBody, Margin = new Thickness(0, 3, Neu.SM, 0), Height = 32,
        };
        combo.SelectionChanged += (_, _) => { if (combo.SelectedItem is string s) { model = s; } };
        r2.Children.Add(combo);
        p.Children.Add(r2);
        p.Children.Add(Neu.Note(msg.Length == 0 ? Hint : msg));
        Content = p;
    }

    void Load()
    {
        loading = true; Build();
        var u = url;
        Task.Run(() =>
        {
            var bad = LocalEndpoint.UrlProblem(u);
            var r = bad == null ? LocalEndpoint.ListModels(u, 3) : null;
            Gui.OnUi(() =>
            {
                loading = false;
                if (bad != null) { msg = bad; models = []; }
                else if (r is not { } res) { msg = $"連不上 {u}——Ollama 或 LM Studio 有開著嗎？"; models = []; }
                else
                {
                    models = res.Models;
                    if (model.Length == 0 || !models.Contains(model)) model = models.FirstOrDefault(x => x == LocalEndpoint.SuggestedModel) ?? models.FirstOrDefault() ?? "";
                    msg = models.Count == 0 ? "連上了，但裡面還沒有模型。" + Hint : $"連上了（{(res.Flavor == LocalEndpoint.Flavor.Ollama ? "Ollama" : "OpenAI 相容端點")}），有 {models.Count} 個模型。選好按「存」。";
                }
                Build();
            });
        });
    }

    void Save()
    {
        if (LocalEndpoint.UrlProblem(url) is { } bad) { msg = bad; Build(); return; }
        var u = Str.TrimWSNL(url);
        ConfigStore.Shared.Update(c => { c.EndpointURL = u == LocalEndpoint.DefaultUrl ? null : u; c.EndpointModel = model; });
        msg = $"已存：之後的會議交給「{model}」整理。";
        Build();
        onSaved();
    }
}
