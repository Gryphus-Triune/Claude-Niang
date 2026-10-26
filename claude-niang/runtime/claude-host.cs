// Finds the Claude desktop main window (Electron, Chrome_WidgetWin_1).
// Shared by widget.ps1 and supervisor.ps1. Read-only: nothing here changes
// the Claude window.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class ClaudeHostInfo { public long handle; public int pid; public long started; public bool visible; public int width; public int height; }

public static class ClaudeHostWindow {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint command);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder text, int size);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder text, int size);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attribute, out uint value, int size);

  static readonly int Session = CurrentSession();
  static int CurrentSession() { using (var process = Process.GetCurrentProcess()) return process.SessionId; }
  static readonly Dictionary<int, KeyValuePair<bool, long>> processCache = new Dictionary<int, KeyValuePair<bool, long>>();

  // Squirrel install: %LOCALAPPDATA%\AnthropicClaude\app-x.y.z\claude.exe
  // Store / MSIX install: C:\Program Files\WindowsApps\Claude_<version>_x64__<id>\...\claude.exe
  public static bool ClaudeExecutable(string file) {
    if (String.IsNullOrEmpty(file)) return false;
    string name = Path.GetFileName(file);
    if (!name.Equals("claude.exe", StringComparison.OrdinalIgnoreCase)) return false;
    if (file.IndexOf("\\AnthropicClaude\\", StringComparison.OrdinalIgnoreCase) >= 0) return true;
    if (file.IndexOf("\\WindowsApps\\Claude_", StringComparison.OrdinalIgnoreCase) >= 0) return true;
    if (file.IndexOf("\\WindowsApps\\Anthropic", StringComparison.OrdinalIgnoreCase) >= 0) return true;
    try {
      FileVersionInfo info = FileVersionInfo.GetVersionInfo(file);
      string company = info.CompanyName ?? "";
      string product = info.ProductName ?? "";
      return company.IndexOf("Anthropic", StringComparison.OrdinalIgnoreCase) >= 0 && product.IndexOf("Claude", StringComparison.OrdinalIgnoreCase) >= 0;
    } catch (Exception) { return false; }
  }

  public static bool ClaudeProcess(int pid) {
    long now = Environment.TickCount;
    lock (processCache) {
      KeyValuePair<bool, long> known;
      // Short-lived cache: a PID can be reused by another program later.
      if (processCache.TryGetValue(pid, out known) && unchecked(now - known.Value) < 60000) return known.Key;
    }
    bool result = false;
    try {
      using (Process process = Process.GetProcessById(pid)) {
        if (process.SessionId == Session && process.ProcessName.Equals("claude", StringComparison.OrdinalIgnoreCase)) {
          string file = null;
          try { file = process.MainModule.FileName; } catch (Exception) { file = null; }
          // Without access to the path (rare), the window checks still apply.
          result = file == null || ClaudeExecutable(file);
        }
      }
    } catch (Exception) { result = false; }
    lock (processCache) { if (processCache.Count > 256) processCache.Clear(); processCache[pid] = new KeyValuePair<bool, long>(result, now); }
    return result;
  }

  // A top-level app window: not a tool or non-activating window, either shown
  // in the taskbar or unowned, and resizable/maximizable like a main window.
  public static bool MainWindowStyle(long style, long extended, bool owned) {
    if ((extended & 0x80) != 0 || (extended & 0x08000000) != 0) return false;
    if ((extended & 0x40000) == 0 && owned) return false;
    return (style & 0x10000) != 0 || (style & 0x40000) != 0;
  }

  public static bool IsCandidate(IntPtr h) {
    if (h == IntPtr.Zero || !IsWindow(h)) return false;
    var cls = new StringBuilder(128); GetClassName(h, cls, 128);
    if (cls.ToString() != "Chrome_WidgetWin_1") return false;
    var title = new StringBuilder(256); GetWindowText(h, title, 256);
    if (title.Length == 0) return false;
    bool owned = GetWindow(h, 4) != IntPtr.Zero;
    if (!MainWindowStyle(GetWindowLongPtr(h, -16).ToInt64(), GetWindowLongPtr(h, -20).ToInt64(), owned)) return false;
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (!ClaudeProcess((int)pid)) return false;
    // Small popups (quick entry, notifications) are not the chat window.
    // A minimized or hidden main window keeps its identity for pause matching.
    if (IsIconic(h) || !IsWindowVisible(h)) return true;
    Rect r; if (!GetWindowRect(h, out r)) return false;
    double scale = 1.0;
    try { scale = Math.Max(1.0, GetDpiForWindow(h) / 96.0); } catch (EntryPointNotFoundException) { scale = 1.0; }
    return (r.Right - r.Left) >= 360 * scale && (r.Bottom - r.Top) >= 300 * scale;
  }

  public static bool VisibleSurface(IntPtr h) {
    uint cloaked;
    return IsWindowVisible(h) && !IsIconic(h) && (DwmGetWindowAttribute(h, 14, out cloaked, 4) != 0 || cloaked == 0);
  }

  public static IntPtr Find() {
    IntPtr foreground = GetAncestor(GetForegroundWindow(), 2);
    if (VisibleSurface(foreground) && IsCandidate(foreground)) return foreground;
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (VisibleSurface(h) && IsCandidate(h)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static IntPtr ForegroundHost(IntPtr h) {
    IntPtr root = GetAncestor(h, 2);
    return IsCandidate(root) ? root : IntPtr.Zero;
  }

  // Readiness without UI Automation (which would switch on accessibility in Claude).
  public static bool LooksReady(IntPtr h) {
    return VisibleSurface(h) && IsCandidate(h);
  }

  public static ClaudeHostInfo Inspect(IntPtr h) {
    try {
      if (!IsCandidate(h)) return null;
      uint pid; GetWindowThreadProcessId(h, out pid);
      Rect r; GetWindowRect(h, out r);
      using (Process process = Process.GetProcessById((int)pid)) {
        return new ClaudeHostInfo { handle = h.ToInt64(), pid = process.Id, started = process.StartTime.ToUniversalTime().Ticks, visible = VisibleSurface(h), width = r.Right - r.Left, height = r.Bottom - r.Top };
      }
    } catch (Exception) { return null; }
  }

  public static ClaudeHostInfo[] Hosts() {
    var hosts = new List<ClaudeHostInfo>();
    EnumWindows(delegate(IntPtr h, IntPtr p) { var host = Inspect(h); if (host != null) hosts.Add(host); return true; }, IntPtr.Zero);
    return hosts.ToArray();
  }

  public static int ProcessId(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return (int)pid; }
}
