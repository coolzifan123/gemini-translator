#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

NODE_EXE    := "C:\Program Files\nodejs\node.exe"
AGY_EXE     := EnvGet("LOCALAPPDATA") "\agy\bin\agy.exe"
SERVER_JS   := A_ScriptDir "\agy-server.js"
WORK_DIR    := A_ScriptDir "\workspace"   ; Antigravity CLI 的工作目录
CONFIG_FILE := A_ScriptDir "\config.ini"  ; 个人设置，在托盘菜单“设置…”里修改
AGENT_FILE  := WORK_DIR "\.agents\agents\translator\agent.md"

#Include lib\config.ahk
#Include lib\settings.ahk
#Include lib\selbutton.ahk

Cfg := LoadConfig()
TRANSLATE_HOTKEY := Cfg["Hotkey"]
MODEL            := Cfg["Model"]
SERVER_PORT      := Cfg["Port"]
TIMEOUT_MS       := Cfg["TimeoutSec"] * 1000
POPUP_WIDTH      := Cfg["PopupWidth"]   ; 弹窗文字区宽度（按 96 DPI 计，会随系统缩放）
FONT_NAME        := Cfg["FontName"]
FONT_SIZE        := Cfg["FontSize"]

SCALE     := A_ScreenDPI / 96
TEXT_W    := Round(POPUP_WIDTH * SCALE)
TOKEN     := Format("{:08x}{:08x}", Random(0, 0x7FFFFFFF), Random(0, 0x7FFFFFFF))  ; 只有本脚本能调用翻译服务

for path in [NODE_EXE, AGY_EXE, SERVER_JS] {
    if !FileExist(path) {
        DllCall("GetFileAttributesW", "Str", path, "UInt")
        diag := Format("错误码 {1}，上级目录可见 {2}，管理员 {3}，AppContainer {4}，{5} {6}"
            , A_LastError, FileExist(RegExReplace(path, "\\[^\\]+$")) != "", A_IsAdmin, IsAppContainer(), A_AhkPath, A_AhkVersion)
        try FileAppend(A_Now " 找不到 " path "`n" diag "`n", A_Temp "\gemini-translate-startup-error.txt", "UTF-8")
        MsgBox("找不到：`n" path "`n`n诊断：" diag, "Gemini 划词翻译", "Iconx")
        ExitApp()
    }
}

IsAppContainer() {
    hToken := 0, isAC := 0, len := 0
    DllCall("advapi32\OpenProcessToken", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt", 0x8, "Ptr*", &hToken)
    DllCall("advapi32\GetTokenInformation", "Ptr", hToken, "Int", 29, "UInt*", &isAC, "UInt", 4, "UInt*", &len)  ; TokenIsAppContainer
    DllCall("CloseHandle", "Ptr", hToken)
    return isAC
}
DirCreate(WORK_DIR)

global ServerPid := 0
StartServer()   ; 脚本一启动就让翻译服务预热，第一次翻译也不用等 agy 启动
OnExit((*) => StopServer())

CoordMode("Mouse", "Screen")
try Hotkey(TRANSLATE_HOTKEY, (*) => TranslateSelection())
catch {
    MsgBox("快捷键“" HotkeyToText(TRANSLATE_HOTKEY) "”无法使用，已临时改用 Alt+Q。可以在托盘菜单“设置…”里重新设置。", "Gemini 划词翻译", "Icon!")
    TRANSLATE_HOTKEY := DEFAULTS["Hotkey"]
    Hotkey(TRANSLATE_HOTKEY, (*) => TranslateSelection())
}
A_IconTip := "Gemini 划词翻译（" HotkeyToText(TRANSLATE_HOTKEY) "）"
A_TrayMenu.Insert("1&", "设置…", ShowSettings)
A_TrayMenu.Insert("2&")
A_TrayMenu.Default := "设置…"  ; 双击托盘图标也打开设置
OnMessage(0x0006, OnActivate)  ; WM_ACTIVATE：弹窗失去焦点时关闭

global Job := 0
global Anchor := {x: 0, y: 0}
global Popup, PopupEdit, PopupStatus, PopupCopy
CreatePopup()
if Cfg["SelectionButton"]
    InitSelectionButton()

; ---------------- 翻译服务（agy-server.js）----------------

StartServer() {
    global ServerPid
    cmd := Format('"{1}" "{2}" {3} {4} {5} {6} {7} {8}', NODE_EXE, SERVER_JS, SERVER_PORT, MODEL, TOKEN, ProcessExist()
        , Cfg["MaxTurns"], Cfg["TurnTimeoutSec"] * 1000)
    Run(cmd, A_ScriptDir, "Hide", &pid)
    ServerPid := pid
}

; 服务意外退出时自动重新拉起
EnsureServer() {
    if !ProcessExist(ServerPid) {
        StartServer()
        Sleep(400)  ; 等它开始监听端口
    }
}

StopServer() {
    if ProcessExist(ServerPid)
        RunWait(A_ComSpec " /c taskkill /PID " ServerPid " /T /F", , "Hide")
}

; ---------------- 取词 ----------------

; 快捷键触发：弹窗出现在鼠标位置
TranslateSelection() {
    global Anchor
    MouseGetPos(&mx, &my)
    Anchor := {x: mx, y: my}
    KeyWait("Alt", "T1")
    TranslateText(GetSelectedText())
}

; 快捷键和划词按钮共用
TranslateText(text) {
    HideSelButton()
    Log("translate: copied " StrLen(text) " chars")
    if (text = "") {
        ShowPopup("没有获取到选中的文字。先选中文字，再按 " HotkeyToText(TRANSLATE_HOTKEY) "，或者点“译”按钮。", "", false)
        return
    }
    StartJob(text)
}

GetSelectedText() {
    saved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")
    text := ClipWait(0.8) ? A_Clipboard : ""
    A_Clipboard := saved
    return Trim(text, " `t`r`n")
}

ShouldTranslateToEnglish(text) {
    RegExReplace(text, "[\x{3400}-\x{9FFF}]", "", &cjk)
    RegExReplace(text, "[A-Za-z]", "", &latin)
    return cjk > 0 && cjk * 3 >= latin
}

; ---------------- 发送翻译请求 ----------------

StartJob(text) {
    global Job
    CancelJob()
    EnsureServer()
    toEnglish := ShouldTranslateToEnglish(text)
    label := toEnglish ? "中 → 英" : "→ 中"
    req := ComObject("WinHttp.WinHttpRequest.5.1")
    req.SetProxy(1)                                         ; 直连本机服务，不走系统代理
    req.SetTimeouts(2000, 2000, 5000, TIMEOUT_MS + 5000)    ; 接收超时比下面自己的超时晚一点，让超时提示更明确
    req.Open("POST", Format("http://127.0.0.1:{1}/translate?to={2}", SERVER_PORT, toEnglish ? "en" : "zh"), true)
    req.SetRequestHeader("Content-Type", "text/plain; charset=utf-8")
    req.SetRequestHeader("X-Token", TOKEN)
    req.Send(text)
    Job := {req: req, start: A_TickCount, label: label}
    ShowPopup("翻译中…", label, false)
    SetTimer(CheckJob, 50)
}

CheckJob() {
    global Job
    if !Job {
        SetTimer(CheckJob, 0)
        return
    }
    elapsed := A_TickCount - Job.start
    try {
        done := Job.req.WaitForResponse(0)
    } catch as e {
        label := Job.label
        Log("request error: " e.Message)
        CancelJob()
        ShowPopup("翻译服务出错：" e.Message, label, false)
        return
    }
    if !done {
        if (elapsed > TIMEOUT_MS) {
            label := Job.label
            Log("timeout")
            CancelJob()
            ShowPopup("超时了（" TIMEOUT_MS // 1000 " 秒没有返回），请重试。", label, false)
        } else {
            PopupStatus.Text := Job.label " · 翻译中… " Format("{:.1f}", elapsed / 1000) "s"
        }
        return
    }
    SetTimer(CheckJob, 0)
    j := Job
    Job := 0
    Log("result: HTTP " j.req.Status " after " elapsed " ms")
    status := j.label " · Gemini · " Format("{:.1f}", elapsed / 1000) "s"
    if (j.req.Status = 200)
        ShowPopup(Trim(j.req.ResponseText, " `t`r`n"), status, true)
    else
        ShowPopup("翻译失败：`n" j.req.ResponseText, status, false)
}

CancelJob() {
    global Job
    if !Job
        return
    Log("job cancelled after " (A_TickCount - Job.start) " ms")
    SetTimer(CheckJob, 0)
    try Job.req.Abort()
    Job := 0
}

; ---------------- 弹窗 ----------------

CreatePopup() {
    global Popup, PopupEdit, PopupStatus, PopupCopy
    Popup := Gui("+AlwaysOnTop -Caption +ToolWindow +Border -DPIScale", "Gemini 划词翻译")
    Popup.BackColor := "FFFFFF"
    Popup.MarginX := Round(12 * SCALE)
    Popup.MarginY := Round(10 * SCALE)
    Popup.SetFont("s" FONT_SIZE " c202020", FONT_NAME)
    PopupEdit := Popup.Add("Edit", "xm ym w" TEXT_W " r1 ReadOnly Multi -VScroll -E0x200 BackgroundFFFFFF")
    Popup.SetFont("s" Max(7, FONT_SIZE - 2) " c888888", FONT_NAME)
    copyW := Round(48 * SCALE)
    PopupStatus := Popup.Add("Text", "xm w" (TEXT_W - copyW), "")
    Popup.SetFont("s" Max(7, FONT_SIZE - 2) " c1a73e8", FONT_NAME)
    PopupCopy := Popup.Add("Text", "x+0 yp w" copyW " Right +0x100", "复制")
    PopupCopy.OnEvent("Click", CopyResult)
    Popup.OnEvent("Escape", (*) => HidePopup("Esc"))
}

ShowPopup(text, status, canCopy) {
    pad := Round(6 * SCALE)
    lineH := MeasureHeight("国")
    h := MeasureHeight(text) + lineH // 2
    maxH := Round(A_ScreenHeight * 0.6)
    scroll := h > maxH
    PopupEdit.Opt(scroll ? "+VScroll" : "-VScroll")
    PopupEdit.Value := text
    PopupEdit.Move(, , TEXT_W + pad, scroll ? maxH : h)
    PopupEdit.GetPos(, &ey, , &eh)
    PopupStatus.Move(, ey + eh + pad)
    PopupCopy.Move(, ey + eh + pad)
    PopupStatus.Text := status
    PopupCopy.Text := "复制"
    PopupCopy.Visible := canCopy

    ; 已经显示着的弹窗不能先 Hide 再 Show：隐藏会让它失去焦点，触发“失焦关闭”把刚出来的结果关掉
    visible := DllCall("IsWindowVisible", "Ptr", Popup.Hwnd)
    Popup.Show(visible ? "AutoSize NoActivate" : "Hide AutoSize")
    Popup.GetPos(, , &w, &h)
    x := Anchor.x + Round(12 * SCALE)
    y := Anchor.y + Round(18 * SCALE)
    FitToMonitor(&x, &y, w, h)
    Popup.Move(x, y)
    Popup.Show()
    WinActivate(Popup.Hwnd)
    PostMessage(0x00B1, 0, 0, PopupEdit)  ; EM_SETSEL：光标放到开头，不全选
}

MeasureHeight(text) {
    m := Gui("-DPIScale")
    m.SetFont("s" FONT_SIZE, FONT_NAME)  ; 必须和弹窗正文字体一致，否则算出的高度不对
    t := m.Add("Text", "w" TEXT_W, text)
    t.GetPos(, , , &h)
    m.Destroy()
    return h
}

FitToMonitor(&x, &y, w, h) {
    loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
        if (Anchor.x >= l && Anchor.x < r && Anchor.y >= t && Anchor.y < b) {
            if (y + h > b)                      ; 下面放不下就放到鼠标上方
                y := Anchor.y - h - Round(12 * SCALE)
            x := Min(Max(x, l), r - w)
            y := Min(Max(y, t), b - h)
            return
        }
    }
}

CopyResult(*) {
    A_Clipboard := PopupEdit.Value
    PopupCopy.Text := "已复制"
}

HidePopup(reason := "") {
    if (reason != "")
        Log("popup closed: " reason)
    Popup.Hide()
    CancelJob()
}

OnActivate(wParam, lParam, msg, hwnd) {
    if (hwnd = Popup.Hwnd && (wParam & 0xFFFF) = 0)
        SetTimer(CheckFocusLost, -150)  ; 稍后再确认，弹窗自身刷新造成的短暂失焦不算
}

CheckFocusLost() {
    if (DllCall("IsWindowVisible", "Ptr", Popup.Hwnd) && !WinActive("ahk_id " Popup.Hwnd))
        HidePopup("focus lost")
}

; 调试日志：%TEMP%\gemini-translate\ahk.log
Log(msg) {
    try FileAppend(FormatTime(, "HH:mm:ss") "." Format("{:03}", A_MSec) " " msg "`n", A_Temp "\gemini-translate\ahk.log", "UTF-8")
}
