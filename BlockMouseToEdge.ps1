# =====================================================================
# BlockMouseToEdge.ps1
# タッチ対応サブモニタ(Corsair Xeneon Edge など)に
# マウスカーソルが入らないようにブロックする常駐スクリプト。
# タッチ / ペン由来のイベントは絶対にブロックしない。
#
# ブロック対象モニタの決め方(優先順):
#   1. 解像度 2560x720(縦置きなら 720x2560)のモニタを自動検出
#   2. 同フォルダの config.json に保存された前回の選択
#   3. 選択画面を表示してユーザーに選んでもらう
# 選択結果は毎回 config.json に保存されます。
#
# 停止するには stop.vbs をダブルクリック(または stop.ps1 を実行)。
# =====================================================================

$ErrorActionPreference = 'Stop'

# スクリプト内のどこでエラーが起きてもログに残す(調査用)
trap {
    $log = Join-Path $PSScriptRoot 'error.log'
    "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_ | Out-File -FilePath $log -Append -Encoding utf8
    exit 1
}

# --- 二重起動防止(名前付きミューテックス) ---
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\XeneonEdgeMouseBlockMutex', [ref]$createdNew)
if (-not $createdNew) {
    # すでに起動中なので何もせず終了
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$configPath = Join-Path $PSScriptRoot 'config.json'

# =====================================================================
# ブロック対象モニタの決定
# =====================================================================
function Select-TargetScreen {
    $screens = [System.Windows.Forms.Screen]::AllScreens

    # モニタが 1 台しかない場合はブロックすると操作不能になるため終了
    if ($screens.Count -lt 2) {
        [System.Windows.Forms.MessageBox]::Show(
            "モニタが 1 台しか見つかりませんでした。`nこのツールはサブモニタがあるときだけ使えます。",
            "Xeneon Edge マウスブロック",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $null
    }

    # --- 1) 解像度で自動検出(2560x720 / 縦置き 720x2560、メイン以外) ---
    $auto = $screens | Where-Object {
        -not $_.Primary -and (
            ($_.Bounds.Width -eq 2560 -and $_.Bounds.Height -eq 720) -or
            ($_.Bounds.Width -eq 720  -and $_.Bounds.Height -eq 2560)
        )
    } | Select-Object -First 1
    if ($auto) { return $auto }

    # --- 2) 保存済み設定(config.json) ---
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # まず現在のモニタ一覧からデバイス名で探す(配置変更に追従)
            $byName = $screens | Where-Object { $_.DeviceName -eq $cfg.deviceName -and -not $_.Primary } | Select-Object -First 1
            if ($byName) { return $byName }
            # 見つからなければ保存済みの矩形をそのまま使う
            if ($null -ne $cfg.left -and $null -ne $cfg.width) {
                return [PSCustomObject]@{
                    DeviceName = [string]$cfg.deviceName
                    Primary    = $false
                    Bounds     = New-Object System.Drawing.Rectangle([int]$cfg.left, [int]$cfg.top, [int]$cfg.width, [int]$cfg.height)
                }
            }
        } catch { }  # 設定が壊れていたら選択画面へ
    }

    # --- 3) 選択画面 ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "ブロックするモニタを選んでください"
    $form.Size = New-Object System.Drawing.Size(560, 340)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.TopMost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "マウスカーソルを入らせたくないモニタ(タッチ画面)を選んで OK を押してください。"
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size = New-Object System.Drawing.Size(520, 36)
    $form.Controls.Add($label)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(12, 52)
    $list.Size = New-Object System.Drawing.Size(520, 180)
    $list.Font = New-Object System.Drawing.Font("Consolas", 10)
    for ($i = 0; $i -lt $screens.Count; $i++) {
        $s = $screens[$i]
        $tag = if ($s.Primary) { " [メイン画面]" } else { "" }
        $list.Items.Add(("モニタ {0}: {1}x{2}  位置({3},{4}){5}" -f ($i + 1), $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y, $tag)) | Out-Null
    }
    # 最初のメイン以外のモニタを初期選択
    for ($i = 0; $i -lt $screens.Count; $i++) {
        if (-not $screens[$i].Primary) { $list.SelectedIndex = $i; break }
    }
    $form.Controls.Add($list)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "OK"
    $ok.Location = New-Object System.Drawing.Point(340, 250)
    $ok.Size = New-Object System.Drawing.Size(90, 32)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "キャンセル"
    $cancel.Location = New-Object System.Drawing.Point(442, 250)
    $cancel.Size = New-Object System.Drawing.Size(90, 32)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    while ($true) {
        $result = $form.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK -or $list.SelectedIndex -lt 0) { return $null }
        $chosen = $screens[$list.SelectedIndex]
        if ($chosen.Primary) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "選んだのはメイン画面です。メイン画面をブロックするとマウスが使えなくなる恐れがあります。`n本当にこのモニタでよいですか?",
                "確認",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { continue }
        }
        return $chosen
    }
}

$target = Select-TargetScreen
if ($null -eq $target) {
    $mutex.ReleaseMutex(); $mutex.Dispose()
    exit 0
}

# --- 選択結果を config.json に保存(次回以降のフォールバック用) ---
$b = $target.Bounds
[PSCustomObject]@{
    deviceName = $target.DeviceName
    left       = $b.X
    top        = $b.Y
    width      = $b.Width
    height     = $b.Height
} | ConvertTo-Json | Out-File -FilePath $configPath -Encoding utf8

# =====================================================================
# 低レベルマウスフック(C#)
# =====================================================================
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MouseBlocker
{
    private const int WH_MOUSE_LL  = 14;
    private const int WM_MOUSEMOVE = 0x0200;

    // タッチ / ペン由来の注入マウスイベントの dwExtraInfo 署名
    // (dwExtraInfo & 0xFFFFFF00) == 0xFF515700
    private const ulong TOUCH_PEN_SIGNATURE_MASK = 0xFFFFFF00UL;
    private const ulong TOUCH_PEN_SIGNATURE      = 0xFF515700UL;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT   pt;
        public uint    mouseData;
        public uint    flags;
        public uint    time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint   message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint   time;
        public POINT  pt;
    }

    private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    // 重要: デリゲートを静的フィールドに保持して GC 回収を防ぐ
    private static LowLevelMouseProc _proc = HookCallback;
    private static IntPtr _hookId = IntPtr.Zero;

    // ブロック対象モニタの矩形(仮想デスクトップ座標。負の値もあり得る)
    private static int _left, _top, _right, _bottom;

    // 直前の「ブロック対象外」でのカーソル位置(クランプ方向の決定に使う)
    private static int  _lastX, _lastY;
    private static bool _hasLast = false;

    private static bool InRect(int x, int y)
    {
        return x >= _left && x < _right && y >= _top && y < _bottom;
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            MSLLHOOKSTRUCT info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));

            ulong extra = info.dwExtraInfo.ToUInt64();
            bool isTouchOrPen = (extra & TOUCH_PEN_SIGNATURE_MASK) == TOUCH_PEN_SIGNATURE;

            // タッチ / ペンは絶対に素通し。マウス由来の移動のみ判定。
            if (!isTouchOrPen && wParam.ToInt64() == WM_MOUSEMOVE)
            {
                if (InRect(info.pt.x, info.pt.y))
                {
                    // 直前の有効位置がある側の境界にクランプ
                    int nx = info.pt.x;
                    int ny = info.pt.y;
                    if (_hasLast)
                    {
                        if      (_lastX <  _left)   nx = _left  - 1;
                        else if (_lastX >= _right)  nx = _right;
                        if      (_lastY <  _top)    ny = _top   - 1;
                        else if (_lastY >= _bottom) ny = _bottom;
                    }
                    if (InRect(nx, ny))
                    {
                        // まだ矩形内(初回など)→ 最も近い辺の外側へ押し出す
                        int dl = nx - _left, dr = _right - 1 - nx;
                        int dt = ny - _top,  db = _bottom - 1 - ny;
                        int m = Math.Min(Math.Min(dl, dr), Math.Min(dt, db));
                        if      (m == dl) nx = _left  - 1;
                        else if (m == dr) nx = _right;
                        else if (m == dt) ny = _top   - 1;
                        else              ny = _bottom;
                    }
                    SetCursorPos(nx, ny);
                    return (IntPtr)1;
                }
                else
                {
                    _lastX = info.pt.x;
                    _lastY = info.pt.y;
                    _hasLast = true;
                }
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    public static void Run(int left, int top, int width, int height)
    {
        _left = left; _top = top; _right = left + width; _bottom = top + height;

        _hookId = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
        if (_hookId == IntPtr.Zero)
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SetWindowsHookEx failed");
        }

        // メッセージループで常駐(プロセスが終了するとフックは自動解除される)
        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }

        UnhookWindowsHookEx(_hookId);
    }
}
'@

try {
    # ブロック開始(このプロセスが生きている間ずっと有効)
    [MouseBlocker]::Run($b.X, $b.Y, $b.Width, $b.Height)
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
