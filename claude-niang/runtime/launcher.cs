// Claude Niang launcher. Compiled at install time into
// runtime\claude-niang-launcher.exe as a windowless (GUI subsystem) program.
//   launcher.exe supervisor : runs runtime\supervisor.ps1 and waits for it,
//                             returning its exit code (Task Scheduler, Startup).
//   launcher.exe open       : runs runtime\start-supervisor.ps1 and returns.
//   launcher.exe check      : returns 0 at once (can this program run here?).
// PowerShell is started with CREATE_NO_WINDOW. Started from Task Scheduler with
// a normal window instead, Windows 11 hands its console to Windows Terminal,
// where -WindowStyle Hidden cannot hide it, and closing that empty window ended
// the supervisor. This replaces the earlier wscript/VBScript launchers, which
// stop working where Windows Script Host is disabled or VBScript is removed.
using System;
using System.Diagnostics;
using System.IO;

static class ClaudeNiangLauncher {
  static int Main(string[] args) {
    string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "supervisor";
    // The installer runs "check" to learn whether policy lets this program run.
    if (mode == "check") return 0;
    if (mode != "supervisor" && mode != "open") return 2;
    string runtime = Path.GetDirectoryName(Path.GetFullPath(typeof(ClaudeNiangLauncher).Assembly.Location));
    string script = Path.Combine(runtime, mode == "open" ? "start-supervisor.ps1" : "supervisor.ps1");
    string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
    ProcessStartInfo info = new ProcessStartInfo(powershell,
      "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
    info.UseShellExecute = false;
    info.CreateNoWindow = true;
    info.WorkingDirectory = Environment.SystemDirectory;
    using (Process process = Process.Start(info)) {
      if (mode == "open") return 0;
      process.WaitForExit();
      return process.ExitCode;
    }
  }
}
