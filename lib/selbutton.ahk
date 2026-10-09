; 划词按钮：用鼠标拖选或双击选中文字后，在鼠标旁边显示一个“译”按钮，点一下就翻译。
; 只在按住鼠标期间光标变成过文本输入的“I”形时才显示，避免拖窗口、拖文件时误弹。
; 显示按钮时不复制任何东西；点了按钮才去复制选中的文字。
; 依赖主脚本的 SCALE、FONT_NAME、Anchor、FitToMonitor、TranslateText、Log。

global SelBtn := 0
global SelDown := {x: 0, y: 0, ibeam: false, own: true}
global SelLastUp := {t: 0, x: 0, y: 0}
global SelAnchor := {x: 0, y: 0}
SEL_BTN_HIDE_MS := 4000        ; 按钮多久不点就自动消失
SEL_HOOK_REFRESH_MS := 30000   ; 多久重装一次鼠标钩子

InitSelectionButton() {
    global SelBtn
    ; WS_EX_NOACTIVATE：点按钮不会抢走原窗口的焦点，选区还在，之后的 Ctrl+C 才能复制到
    SelBtn := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale", "Gemini 划词按钮")
    SelBtn.BackColor := "1A73E8"
    SelBtn.MarginX := 0, SelBtn.MarginY := 0
    SelBtn.SetFont("s10 bold cFFFFFF", FONT_NAME)
    size := Round(26 * SCALE)
    btn := SelBtn.Add("Text", "w" size " h" size " Center +0x200 +0x100 BackgroundTrans", "译")  ; 0x200 垂直居中，0x100 可点击
    btn.OnEvent("Click", OnSelButtonClick)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", SelBtn.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)  ; Windows 11 圆角
    Hotkey("~LButton", OnSelMouseDown)
    Hotkey("~LButton Up", OnSelMouseUp)
    ; Windows 会悄悄停用响应慢的鼠标钩子（比如电脑很卡、刚睡眠唤醒），之后装了钩子的软件也可能把点击吞掉，
    ; 这两种情况下按钮都会再也不出现。定时重装一次，让它自己恢复，也重新排到别的钩子前面
    SetTimer(RefreshMouseHook, SEL_HOOK_REFRESH_MS)
    OnMessage(0x0218, OnPowerBroadcast)  ; WM_POWERBROADCAST
}

OnSelMouseDown(*) {
    global SelDown
    MouseGetPos(&x, &y, &win)
    if (win = SelBtn.Hwnd)  ; 点的是按钮本身，交给按钮的点击事件处理
        return
    HideSelButton()
    SelDown := {x: x, y: y, ibeam: A_Cursor = "IBeam", own: IsOwnWindow(win)}
    if (!SelDown.own && !SelDown.ibeam)
        SetTimer(WatchSelCursor, 30)
}

; 从文字旁边的空白处开始拖时，按下那一刻光标还是箭头；拖的过程中光标变成过“I”形也算在选文字
WatchSelCursor() {
    if !GetKeyState("LButton") {
        SetTimer(WatchSelCursor, 0)
        return
    }
    if (A_Cursor = "IBeam") {
        SelDown.ibeam := true
        SetTimer(WatchSelCursor, 0)
    }
}

OnSelMouseUp(*) {
    global SelLastUp
    SetTimer(WatchSelCursor, 0)
    MouseGetPos(&x, &y, &win)
    if (win = SelBtn.Hwnd)
        return
    near := Round(8 * SCALE)
    isDouble := A_TickCount - SelLastUp.t < DllCall("GetDoubleClickTime")
        && Abs(x - SelLastUp.x) < near && Abs(y - SelLastUp.y) < near
    isDrag := Abs(x - SelDown.x) + Abs(y - SelDown.y) > Round(10 * SCALE)
    SelLastUp := {t: A_TickCount, x: x, y: y}
    if (SelDown.own || !SelDown.ibeam)  ; 自己的窗口里（比如在译文里选字）或者不是在文本上，不弹
        return
    if (isDrag || isDouble)
        ShowSelButton(x, y)
}

ShowSelButton(x, y) {
    global SelAnchor, Anchor
    SelAnchor := {x: x, y: y}
    SelBtn.Show("Hide AutoSize")
    SelBtn.GetPos(, , &w, &h)
    bx := x + Round(10 * SCALE)
    by := y + Round(12 * SCALE)
    Anchor := SelAnchor   ; FitToMonitor 按 Anchor 所在的显示器来限制位置
    FitToMonitor(&bx, &by, w, h)
    SelBtn.Show("x" bx " y" by " NoActivate")
    SetTimer(HideSelButton, -SEL_BTN_HIDE_MS)
}

HideSelButton(*) {
    SetTimer(HideSelButton, 0)
    if SelBtn
        SelBtn.Hide()
}

OnSelButtonClick(*) {
    global Anchor
    HideSelButton()
    Anchor := SelAnchor
    Log("selection button clicked")
    TranslateText(GetSelectedText())
}

IsOwnWindow(hwnd) {
    try return WinGetPID(hwnd) = DllCall("GetCurrentProcessId")
    return false
}

RefreshMouseHook() {
    if GetKeyState("LButton")  ; 正按着鼠标（可能在拖选）时不动，免得漏掉这次松开
        return
    InstallMouseHook(true, true)  ; Force：卸掉再重装
}

OnPowerBroadcast(wParam, lParam, msg, hwnd) {
    ; 这条消息会发给脚本的每个顶层窗口，只在主窗口上处理一次
    if (wParam = 0x12 && hwnd = A_ScriptHwnd)  ; PBT_APMRESUMEAUTOMATIC：从睡眠或休眠唤醒
        RefreshMouseHook()
}
