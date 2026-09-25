// Prompt — the record organiser's system prompts (four meeting scenarios, interview, note). Mirrors Polish/Prompt.swift;
// the long literals live in PromptText.cs (generated from the Swift source).
namespace Hearby.Core;

public static class Prompt
{
    public static string System(MeetingScenario? scenario = null, int? onsiteCount = null, bool onsite = false)
    {
        var glossarySection = "";
        if (Clean.LocalGlossary() is { } g) glossarySection = "\n詞彙表（僅供轉寫糾錯參考，不代表這些詞的主人在場）：" + g + "\n";
        var effective = scenario ?? (onsite ? MeetingScenario.Onsite : MeetingScenario.OnlineHeadphones);
        string intro, fallbackNaming, attendeeTag;
        switch (effective)
        {
            case MeetingScenario.Onsite:
            {
                var cc = onsiteCount is { } n ? (n >= 5 ? "現場至少 5 人（含記錄者）。" : $"現場共 {n} 人（含記錄者）——與會者不多於 {n} 人，不要多列。") : "";
                intro = "你是會議紀錄整理器。輸入是一場「現場會議」的逐字稿：[現場]＝現場所有人共用同一支麥克風——不同行可能是不同人說的，禁止把所有發言當成同一個人；發言歸屬除非有明確的自我介紹或被稱呼，否則不要指名。" + cc + "若逐字稿出現[遠端]＝這台電腦播放的內容（影片／錄音素材），不是與會者。";
                fallbackNaming = "「現場A」「現場B」"; attendeeTag = "現場";
                break;
            }
            case MeetingScenario.OnlineHeadphones:
                intro = "你是會議紀錄整理器。輸入是一場會議的雙軌逐字稿：[我方]＝本機麥克風這一側（可能含現場多人），[遠端]＝線上會議對方（可能一人或多人）。";
                fallbackNaming = "「我方」「遠端A」「遠端B」"; attendeeTag = "我方/遠端";
                break;
            case MeetingScenario.OnlineSpeaker:
                intro = "你是會議紀錄整理器。輸入是一場會議的雙軌逐字稿：[我方]＝本機麥克風這一側（可能含現場多人），[遠端]＝線上會議對方（可能一人或多人）。使用者開喇叭開會：[我方]可能錄到遠端聲音的迴聲，明顯重複的句子已自動去除；若[我方]仍出現與[遠端]幾乎相同的句子＝迴聲殘留，以[遠端]為準，不要當成我方發言。";
                fallbackNaming = "「我方」「遠端A」「遠端B」"; attendeeTag = "我方/遠端";
                break;
            default:
            {
                var cc = onsiteCount is { } n ? (n >= 5 ? "現場至少 5 人（含記錄者）" : $"現場共 {n} 人（含記錄者）") + "，電話那頭另有與會者——與會者總數＝現場人數加電話那頭的人。" : "";
                intro = "你是會議紀錄整理器。輸入是一場「電話擴音」會議的逐字稿：[現場]＝單支麥克風收音，混含現場所有人與電話擴音那頭的與會者——不同行可能是不同人說的，禁止把所有發言當成同一個人；發言歸屬除非有明確的自我介紹或被稱呼，否則不要指名，電話那頭無法確定名字就標「電話端」。" + cc;
                fallbackNaming = "「現場A」「現場B」「電話端」"; attendeeTag = "現場/電話端";
                break;
            }
        }
        return intro + PromptText.MeetingBody(fallbackNaming, glossarySection, attendeeTag);
    }

    /// Interview (Q&A): a quotable interview transcript
    public static string Interview()
    {
        var glossarySection = Clean.LocalGlossary() is { } g ? "\n詞彙表（轉寫糾錯參考）：" + g + "\n" : "";
        return PromptText.Interview(glossarySection);
    }

    /// Note (one speaker): an edited article, no attendees / decisions
    public static string Note()
    {
        var glossarySection = Clean.LocalGlossary() is { } g ? "\n詞彙表（轉寫糾錯參考）：" + g + "\n" : "";
        return PromptText.Note(glossarySection);
    }

    public static string Translate(string language) => PromptText.Translate(language switch
    {
        "en" => "English", "ja" => "Japanese", "zh-CN" => "Simplified Chinese", _ => language,
    });

    public static string SectionEdit(string sectionName, string instruction) => PromptText.SectionEdit(sectionName, instruction);

    /// Extra rules for small local models (Ollama / LM Studio): the same rules, said once more, shorter and blunter
    public static string LocalModelRules => PromptText.LocalModelRules;
}
