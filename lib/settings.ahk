; 设置窗口：托盘菜单“设置…”打开；保存后重启脚本，让新设置（包括后台服务）生效。
; 依赖 config.ahk，以及调用方定义的 AGY_EXE、WORK_DIR、TRANSLATE_HOTKEY。

global SettingsGui := 0, S := {}, ModelJob := 0

LABELS := Map(
    "TimeoutSec",     "等待超时",
    "PopupWidth",     "弹窗宽度",
    "FontSize",       "字号",
    "Port",           "服务端口",
    "MaxTurns",       "每个对话最多翻译",
    "TurnTimeoutSec", "服务端单条超时",
)
FONT_CHOICES := ["Microsoft YaHei UI", "微软雅黑", "等线", "黑体", "宋体", "楷体", "Segoe UI", "Consolas"]

ShowSettings(*) => OpenSettings()

OpenSettings(showOpts := "") {
    global SettingsGui, S
    if SettingsGui {
        SettingsGui.Show()
        return
    }
    ; 打开设置时先关掉翻译快捷键，否则在快捷键输入框里按 Alt+Q 会直接触发翻译。
    ; 不用 Suspend：它会把“译”按钮也一起停掉，设置窗口被别的窗口挡住时，看起来就像程序坏了
    try Hotkey(TRANSLATE_HOTKEY, "Off")
    cfg := LoadConfig()
    g := Gui("-MinimizeBox", "Gemini 划词翻译 · 设置")
    g.SetFont("s9", "Microsoft YaHei UI")
    g.MarginX := 16, g.MarginY := 14
    S := {Num: Map()}
    S.Tab := g.Add("Tab3", "w500 h372", ["常规", "翻译规则", "高级"])

    ; ---------- 常规 ----------
    S.Tab.UseTab(1)
    g.Add("Text", "Section w110", "翻译快捷键")
    S.Hotkey := g.Add("Hotkey", "x+8 yp-3 w170", cfg["Hotkey"])
    AddHint(g, "点一下输入框，再按下想用的组合键（支持 Ctrl / Alt / Shift）")

    g.Add("Text", "xs y+16 w110", "模型")
    S.Model := g.Add("DropDownList", "x+8 yp-3 w230")
    S.RefreshBtn := g.Add("Button", "x+6 yp-1 w90", "刷新列表")
    S.RefreshBtn.OnEvent("Click", RefreshModels)
    S.ModelStatus := AddHint(g, "")
    models := LoadModelCache()
    SetModelChoices(models, cfg["Model"])
    S.ModelStatus.Text := models.Length ? ModelHint(models.Length) : "还没有模型列表，正在获取…"

    AddNumber(g, "TimeoutSec", "等待超时", cfg, "秒，超过就提示失败")
    AddNumber(g, "PopupWidth", "弹窗宽度", cfg, "像素")
    g.Add("Text", "xs y+16 w110", "字体")
    S.FontName := g.Add("ComboBox", "x+8 yp-3 w230", FONT_CHOICES)
    S.FontName.Text := cfg["FontName"]
    AddNumber(g, "FontSize", "字号", cfg, "磅")
    S.SelButton := g.Add("CheckBox", "xs y+20", "划词后显示“译”按钮（拖选或双击选中文字时出现）")
    S.SelButton.Value := cfg["SelectionButton"]
    S.AutoStart := g.Add("CheckBox", "xs y+10", "开机自动启动")
    S.AutoStart.Value := IsAutoStart()

    ; ---------- 翻译规则 ----------
    S.Tab.UseTab(2)
    g.Add("Text", "Section w460", "发给模型的翻译规则（系统提示）。每条请求会写明“翻译成英文”或“翻译成简体中文”，原文放在 <text> 标签里。")
    S.Rules := g.Add("Edit", "xs y+8 w460 h250 Multi WantReturn", ReadRules())
    g.Add("Button", "xs y+8", "恢复默认规则").OnEvent("Click", (*) => S.Rules.Value := DEFAULT_RULES)

    ; ---------- 高级 ----------
    S.Tab.UseTab(3)
    g.Add("Text", "Section w460 c666666", "一般不需要修改。")
    AddNumber(g, "Port", "服务端口", cfg, "本机端口，和别的程序冲突时再改")
    AddNumber(g, "MaxTurns", "每个对话最多翻译", cfg, "条，超过后自动开一个新对话")
    AddNumber(g, "TurnTimeoutSec", "服务端单条超时", cfg, "秒")
    g.Add("Button", "xs y+24", "打开服务日志").OnEvent("Click", (*) => OpenPath(A_Temp "\gemini-translate\agy-server.log"))
    g.Add("Button", "x+8 yp", "打开程序文件夹").OnEvent("Click", (*) => OpenPath(A_ScriptDir))

    ; ---------- 底部按钮 ----------
    S.Tab.UseTab()
    g.Add("Button", "xm y398 w110", "全部恢复默认").OnEvent("Click", ResetToDefaults)
    g.Add("Button", "x326 yp w100 Default", "保存并应用").OnEvent("Click", SaveSettings)
    g.Add("Button", "x+8 yp w82", "取消").OnEvent("Click", CloseSettings)
    g.OnEvent("Close", CloseSettings)
    g.OnEvent("Escape", CloseSettings)

    SettingsGui := g
    g.Show(showOpts)
    if !models.Length
        RefreshModels()
}

AddHint(g, text) => g.Add("Text", "xs+118 y+4 w340 c888888", text)

AddNumber(g, key, label, cfg, unit) {
    g.Add("Text", "xs y+16 w110", label)
    S.Num[key] := g.Add("Edit", "x+8 yp-3 w80 Number", cfg[key])
    g.Add("UpDown", "0x80 Range" LIMITS[key][1] "-" LIMITS[key][2], cfg[key])  ; 0x80：数字不加千位分隔符
    g.Add("Text", "x+8 yp+3 c888888", unit)
}

ModelHint(n) => "共 " n " 个模型。flash-low 最快，其余更准但更慢"

SetModelChoices(list, current) {
    list := list.Clone()
    found := 0
    for i, m in list
        if (m = current)
            found := i
    if !found {
        list.InsertAt(1, current)
        found := 1
    }
    S.Model.Delete()
    S.Model.Add(list)
    S.Model.Choose(found)
}

; 在后台运行 agy models 获取模型列表，不卡住窗口
RefreshModels(*) {
    global ModelJob
    if ModelJob
        return
    file := A_Temp "\gemini-translate\models.txt"
    DirCreate(A_Temp "\gemini-translate")
    try FileDelete(file)
    Run(Format('{1} /c ""{2}" models > "{3}" 2>nul"', A_ComSpec, AGY_EXE, file), WORK_DIR, "Hide", &pid)
    ModelJob := {pid: pid, file: file, start: A_TickCount}
    S.ModelStatus.Text := "正在获取模型列表…"
    S.RefreshBtn.Enabled := false
    SetTimer(PollModels, 200)
}

PollModels() {
    global ModelJob
    if !ModelJob {
        SetTimer(PollModels, 0)
        return
    }
    if (ProcessExist(ModelJob.pid) && A_TickCount - ModelJob.start < 30000)
        return
    SetTimer(PollModels, 0)
    job := ModelJob
    ModelJob := 0
    try ProcessClose(job.pid)
    list := []
    try {
        for line in StrSplit(FileRead(job.file, "UTF-8"), "`n", "`r") {
            id := Trim(StrSplit(line, "`t")[1])
            if RegExMatch(id, "^[a-z0-9][a-z0-9.\-]+$")
                list.Push(id)
        }
    }
    try FileDelete(job.file)
    if !SettingsGui  ; 窗口已经关了
        return
    S.RefreshBtn.Enabled := true
    if !list.Length {
        S.ModelStatus.Text := "获取失败，请检查网络后点“刷新列表”重试"
        return
    }
    SaveModelCache(list)
    SetModelChoices(list, S.Model.Text)
    S.ModelStatus.Text := ModelHint(list.Length)
}

ResetToDefaults(*) {
    S.Hotkey.Value := DEFAULTS["Hotkey"]
    SetModelChoices(LoadModelCache(), DEFAULTS["Model"])
    S.FontName.Text := DEFAULTS["FontName"]
    S.SelButton.Value := DEFAULTS["SelectionButton"]
    for key, ctl in S.Num
        ctl.Value := DEFAULTS[key]
    S.Rules.Value := DEFAULT_RULES
}

SaveSettings(*) {
    cfg := Map()
    cfg["Hotkey"] := S.Hotkey.Value
    if (cfg["Hotkey"] = "")
        return SettingsError(1, "请设置翻译快捷键。")
    cfg["Model"] := S.Model.Text
    cfg["SelectionButton"] := S.SelButton.Value
    cfg["FontName"] := Trim(S.FontName.Text)
    if (cfg["FontName"] = "")
        return SettingsError(1, "请填写字体。")
    for key, ctl in S.Num {
        lim := LIMITS[key]
        val := ctl.Value
        if (!IsInteger(val) || val < lim[1] || val > lim[2])
            return SettingsError(key = "Port" || key = "MaxTurns" || key = "TurnTimeoutSec" ? 3 : 1
                , Format("“{1}”需要是 {2} 到 {3} 之间的整数。", LABELS[key], lim[1], lim[2]))
        cfg[key] := Integer(val)
    }
    rules := Trim(S.Rules.Value, " `t`r`n")
    if (rules = "")
        return SettingsError(2, "翻译规则不能为空。可以点“恢复默认规则”。")
    ; 放在最后检查：注册一个关闭状态的同名快捷键来验证，验证通过后马上重启脚本，不影响现有快捷键
    try Hotkey(cfg["Hotkey"], (*) => 0, "Off")
    catch
        return SettingsError(1, "快捷键“" HotkeyToText(cfg["Hotkey"]) "”无法使用，请换一个。")

    SaveConfig(cfg)
    if (StrReplace(rules, "`r`n", "`n") != ReadRules())
        WriteRules(rules)
    try SetAutoStart(S.AutoStart.Value)
    catch as e
        MsgBox("开机自启设置失败：" e.Message, "Gemini 划词翻译", "Icon!")
    Reload()
}

SettingsError(tabIndex, msg) {
    S.Tab.Choose(tabIndex)
    MsgBox(msg, "Gemini 划词翻译 · 设置", "Icon!")
}

CloseSettings(*) {
    global SettingsGui, ModelJob
    SetTimer(PollModels, 0)
    if ModelJob {
        try ProcessClose(ModelJob.pid)
        ModelJob := 0
    }
    SettingsGui.Destroy()
    SettingsGui := 0
    try Hotkey(TRANSLATE_HOTKEY, "On")
}

OpenPath(path) {
    if FileExist(path)
        Run(path)
    else
        MsgBox("还没有这个文件：`n" path, "Gemini 划词翻译", "Iconi")
}
