// Claude娘 · WebView2 helper. Compiled at runtime by claude-browser.ps1 (C# 5).
// The helper is the widget's own small browser: the user signs in to claude.ai
// in a visible window once, and later quota reads reuse that profile.
// Page scripts are disabled for quota reads and challenges are never solved
// automatically; they are reported so the user can open the visible window.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;

public static class ClaudeNiangWeb {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr LoadLibraryW(string path);
  [DllImport("user32.dll")]
  static extern bool SetProcessDpiAwarenessContext(IntPtr value);

  public static string Architecture() {
    string value = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") ?? "";
    value = value.ToUpperInvariant();
    if (value == "ARM64") return "arm64";
    if (value == "X86") return "x86";
    return "x64";
  }

  public static void PrepareLoader(string sdkDir) {
    string dir = Path.Combine(sdkDir, Architecture());
    string loader = Path.Combine(dir, "WebView2Loader.dll");
    if (!File.Exists(loader)) throw new FileNotFoundException("WebView2Loader.dll is missing", loader);
    try { CoreWebView2Environment.SetLoaderDllFolderPath(dir); } catch (Exception) { }
    LoadLibraryW(loader);
  }

  public static void EnableDpiAwareness() {
    try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (Exception) { }
  }

  public static string RuntimeVersion() {
    try { return CoreWebView2Environment.GetAvailableBrowserVersionString(); } catch (Exception) { return null; }
  }

  // The helper owns this STA thread: pump its messages until a WebView2
  // callback completes the task (no nested UI besides the hidden host form).
  public static bool Pump(Func<bool> done, int timeoutMs) {
    Stopwatch watch = Stopwatch.StartNew();
    while (!done()) {
      if (watch.ElapsedMilliseconds > timeoutMs) return false;
      Application.DoEvents();
      Thread.Sleep(8);
    }
    return true;
  }

  public static T Await<T>(Task<T> task, int timeoutMs, string step) {
    if (!Pump(delegate { return task.IsCompleted; }, timeoutMs)) throw new TimeoutException(step + " timed out");
    if (task.IsFaulted) {
      Exception inner = task.Exception != null ? task.Exception.GetBaseException() : null;
      throw new InvalidOperationException(step + " failed: " + (inner != null ? inner.Message : "unknown"), inner);
    }
    if (task.IsCanceled) throw new OperationCanceledException(step + " was cancelled");
    return task.Result;
  }

  public static void AwaitDone(Task task, int timeoutMs, string step) {
    if (!Pump(delegate { return task.IsCompleted; }, timeoutMs)) throw new TimeoutException(step + " timed out");
    if (task.IsFaulted) {
      Exception inner = task.Exception != null ? task.Exception.GetBaseException() : null;
      throw new InvalidOperationException(step + " failed: " + (inner != null ? inner.Message : "unknown"), inner);
    }
    if (task.IsCanceled) throw new OperationCanceledException(step + " was cancelled");
  }

  public static bool IsClaudeHost(string url) {
    Uri uri;
    if (!Uri.TryCreate(url ?? "", UriKind.Absolute, out uri)) return false;
    string host = uri.Host.ToLowerInvariant();
    return uri.Scheme == Uri.UriSchemeHttps && (host == "claude.ai" || host.EndsWith(".claude.ai"));
  }
}

public sealed class ClaudeNiangResponse {
  public string Url = "";
  public int Status;
  public string ContentType = "";
  public string CfMitigated = "";
  public string RetryAfter = "";
  public string Body = "";
  public string BodyEncoding = "text";
  public string Error = "";
  public string FinalUrl = "";
}

public sealed class ClaudeNiangCookieInfo {
  public bool HasSessionCookie;
  public string LastActiveOrg = "";
  public int Count;
}

public sealed class ClaudeNiangWebSession : IDisposable {
  Form host;
  CoreWebView2Environment environment;
  CoreWebView2Controller controller;
  CoreWebView2 core;
  bool disposed;

  public static ClaudeNiangWebSession Open(string userDataFolder, int timeoutMs) {
    ClaudeNiangWebSession session = new ClaudeNiangWebSession();
    try {
      session.host = new Form();
      session.host.ShowInTaskbar = false;
      session.host.FormBorderStyle = FormBorderStyle.None;
      session.host.StartPosition = FormStartPosition.Manual;
      session.host.Location = new Point(-32000, -32000);
      session.host.Size = new Size(960, 720);
      IntPtr handle = session.host.Handle;
      session.environment = ClaudeNiangWeb.Await(CoreWebView2Environment.CreateAsync(null, userDataFolder, null), timeoutMs, "CreateEnvironment");
      session.controller = ClaudeNiangWeb.Await(session.environment.CreateCoreWebView2ControllerAsync(handle), timeoutMs, "CreateController");
      session.controller.IsVisible = false;
      session.controller.Bounds = new Rectangle(0, 0, 960, 720);
      session.core = session.controller.CoreWebView2;
      CoreWebView2Settings settings = session.core.Settings;
      settings.IsScriptEnabled = false;
      settings.IsWebMessageEnabled = false;
      settings.AreDevToolsEnabled = false;
      settings.AreDefaultContextMenusEnabled = false;
      settings.AreHostObjectsAllowed = false;
      settings.IsStatusBarEnabled = false;
      try { settings.IsPasswordAutosaveEnabled = false; settings.IsGeneralAutofillEnabled = false; } catch (Exception) { }
      // A quota read never opens other windows.
      session.core.NewWindowRequested += delegate(object sender, CoreWebView2NewWindowRequestedEventArgs e) { e.Handled = true; };
      return session;
    } catch {
      session.Dispose();
      throw;
    }
  }

  public ClaudeNiangCookieInfo Cookies(int timeoutMs) {
    ClaudeNiangCookieInfo info = new ClaudeNiangCookieInfo();
    List<CoreWebView2Cookie> cookies = ClaudeNiangWeb.Await(core.CookieManager.GetCookiesAsync("https://claude.ai"), timeoutMs, "GetCookies");
    foreach (CoreWebView2Cookie cookie in cookies) {
      info.Count++;
      if (cookie.Name == "sessionKey" && !string.IsNullOrEmpty(cookie.Value)) info.HasSessionCookie = true;
      if (cookie.Name == "lastActiveOrg" && !string.IsNullOrEmpty(cookie.Value) && cookie.Value.Length <= 64) info.LastActiveOrg = cookie.Value;
    }
    return info;
  }

  static string Header(CoreWebView2HttpResponseHeaders headers, string name) {
    try { return headers.Contains(name) ? (headers.GetHeader(name) ?? "") : ""; } catch (Exception) { return ""; }
  }

  static bool SameResource(string a, string b) {
    Uri x, y;
    if (!Uri.TryCreate(a ?? "", UriKind.Absolute, out x) || !Uri.TryCreate(b ?? "", UriKind.Absolute, out y)) return false;
    return string.Equals(x.GetLeftPart(UriPartial.Query), y.GetLeftPart(UriPartial.Query), StringComparison.OrdinalIgnoreCase);
  }

  // One top-level GET of a claude.ai API address. The response body is taken
  // from the network response itself (not from a rendered page).
  public ClaudeNiangResponse Get(string url, int timeoutMs) {
    ClaudeNiangResponse result = new ClaudeNiangResponse();
    result.Url = url;
    if (!ClaudeNiangWeb.IsClaudeHost(url)) { result.Error = "refused: not claude.ai"; return result; }
    bool navigationDone = false;
    bool responseSeen = false;
    Task<Stream> content = null;
    EventHandler<CoreWebView2WebResourceResponseReceivedEventArgs> onResponse = delegate(object sender, CoreWebView2WebResourceResponseReceivedEventArgs e) {
      try {
        if (responseSeen || !SameResource(e.Request.Uri, url)) return;
        responseSeen = true;
        result.Status = e.Response.StatusCode;
        result.ContentType = Header(e.Response.Headers, "content-type");
        result.CfMitigated = Header(e.Response.Headers, "cf-mitigated");
        result.RetryAfter = Header(e.Response.Headers, "retry-after");
        content = e.Response.GetContentAsync();
      } catch (Exception ex) { result.Error = "response: " + ex.Message; }
    };
    EventHandler<CoreWebView2NavigationCompletedEventArgs> onNavigation = delegate(object sender, CoreWebView2NavigationCompletedEventArgs e) {
      navigationDone = true;
      try {
        if (!e.IsSuccess && result.Status == 0) {
          result.Error = e.WebErrorStatus.ToString();
          try { if (e.HttpStatusCode > 0) result.Status = e.HttpStatusCode; } catch (Exception) { }
        }
      } catch (Exception) { }
    };
    core.WebResourceResponseReceived += onResponse;
    core.NavigationCompleted += onNavigation;
    try {
      core.Navigate(url);
      if (!ClaudeNiangWeb.Pump(delegate { return navigationDone; }, timeoutMs)) { result.Error = "TIMEOUT"; return result; }
      try { result.FinalUrl = core.Source ?? ""; } catch (Exception) { }
      if (content != null) {
        if (ClaudeNiangWeb.Pump(delegate { return content.IsCompleted; }, 15000) && !content.IsFaulted && !content.IsCanceled && content.Result != null) {
          using (StreamReader reader = new StreamReader(content.Result, Encoding.UTF8)) {
            char[] buffer = new char[8192];
            StringBuilder text = new StringBuilder();
            int read;
            while ((read = reader.Read(buffer, 0, buffer.Length)) > 0) {
              text.Append(buffer, 0, read);
              if (text.Length > 4 * 1024 * 1024) break;
            }
            result.Body = text.ToString();
          }
        }
      }
      if (string.IsNullOrEmpty(result.Body) && result.Status != 0) {
        // Fallback for runtimes that do not expose the content: read the
        // displayed text. This injected read works even with page scripts off.
        Task<string> script = core.ExecuteScriptAsync("(function(){var p=document.querySelector('body>pre');return p?p.textContent:(document.body?document.body.innerText:'');})()");
        if (ClaudeNiangWeb.Pump(delegate { return script.IsCompleted; }, 10000) && !script.IsFaulted && !script.IsCanceled) {
          result.Body = script.Result ?? "";
          result.BodyEncoding = "json-string";
        }
      }
    } finally {
      core.WebResourceResponseReceived -= onResponse;
      core.NavigationCompleted -= onNavigation;
    }
    return result;
  }

  public void SignOut(int timeoutMs) {
    core.CookieManager.DeleteAllCookies();
    ClaudeNiangWeb.AwaitDone(core.Profile.ClearBrowsingDataAsync(), timeoutMs, "ClearBrowsingData");
    if (Cookies(timeoutMs).HasSessionCookie) throw new InvalidOperationException("Session data could not be cleared");
  }

  public void Dispose() {
    if (disposed) return;
    disposed = true;
    try { if (controller != null) controller.Close(); } catch (Exception) { }
    controller = null; core = null; environment = null;
    try { if (host != null) host.Dispose(); } catch (Exception) { }
    host = null;
  }
}

// Visible sign-in window. It only watches whether claude.ai has signed in;
// credentials stay inside this WebView2 profile.
public sealed class ClaudeNiangLoginForm : Form {
  readonly string userDataFolder;
  readonly string startUrl;
  readonly Microsoft.Web.WebView2.WinForms.WebView2 view;
  readonly Label hint;
  readonly System.Windows.Forms.Timer closeTimer;
  readonly System.Windows.Forms.Timer pollTimer;
  bool signedIn;
  bool checking;
  public bool SignedIn { get { return signedIn; } }
  public string Failure { get; private set; }

  public ClaudeNiangLoginForm(string userDataFolder, string startUrl) {
    this.userDataFolder = userDataFolder;
    this.startUrl = startUrl;
    Text = "登录 Claude 账号 · Claude 娘";
    StartPosition = FormStartPosition.Manual;
    ClientSize = new Size(520, 760);
    MinimumSize = new Size(360, 420);
    BackColor = Color.FromArgb(250, 246, 241);
    ShowIcon = false;
    hint = new Label();
    hint.Dock = DockStyle.Top;
    hint.Height = 78;
    hint.Padding = new Padding(14, 8, 14, 6);
    hint.BackColor = Color.FromArgb(245, 230, 220);
    hint.ForeColor = Color.FromArgb(106, 64, 46);
    hint.Font = new Font("Microsoft YaHei UI", 9.5f);
    hint.Text = "在下面登录你的 Claude 账号，登录成功后窗口会自动关闭。\r\nGoogle 登录若提示「此浏览器不安全」，请改用 Continue with email：点开邮件里的链接，把浏览器显示的验证码填回这里。";
    view = new Microsoft.Web.WebView2.WinForms.WebView2();
    view.Dock = DockStyle.Fill;
    view.DefaultBackgroundColor = Color.White;
    Controls.Add(view);
    Controls.Add(hint);
    closeTimer = new System.Windows.Forms.Timer();
    closeTimer.Interval = 2500;
    closeTimer.Tick += delegate { closeTimer.Stop(); Close(); };
    // claude.ai is a single-page app: after the code is accepted it may move
    // on without a full navigation, so the sign-in check also runs on a timer.
    pollTimer = new System.Windows.Forms.Timer();
    pollTimer.Interval = 1500;
    pollTimer.Tick += delegate { CheckSignedIn(); };
  }

  // Size the window for this screen's DPI and keep it inside the work area.
  void FitToScreen() {
    try {
      float scale = 1f;
      using (Graphics g = CreateGraphics()) scale = Math.Max(1f, g.DpiX / 96f);
      Rectangle area = Screen.FromPoint(Cursor.Position).WorkingArea;
      hint.Height = (int)(78 * scale);
      hint.Padding = new Padding((int)(14 * scale), (int)(8 * scale), (int)(14 * scale), (int)(6 * scale));
      int width = Math.Max(360, Math.Min((int)(520 * scale), area.Width - 40));
      int height = Math.Max(420, Math.Min((int)(800 * scale), area.Height - 40));
      Bounds = new Rectangle(area.Left + Math.Max(0, (area.Width - width) / 2), area.Top + Math.Max(0, (area.Height - height) / 2), width, height);
    } catch (Exception) { }
  }

  protected override async void OnLoad(EventArgs e) {
    base.OnLoad(e);
    FitToScreen();
    try {
      CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, userDataFolder, null);
      await view.EnsureCoreWebView2Async(environment);
      CoreWebView2 core = view.CoreWebView2;
      core.Settings.AreDevToolsEnabled = false;
      core.Settings.IsStatusBarEnabled = false;
      core.NavigationCompleted += delegate { CheckSignedIn(); };
      core.SourceChanged += delegate { CheckSignedIn(); };
      core.Navigate(startUrl);
      pollTimer.Start();
    } catch (Exception ex) {
      Failure = ex.Message;
      hint.Text = "内置浏览器没能启动：" + ex.Message + "\r\n请确认已安装 Microsoft Edge WebView2 运行时。";
    }
  }

  protected override void OnShown(EventArgs e) {
    base.OnShown(e);
    // Opened from the widget's menu: bring the window in front of Claude.
    try { TopMost = true; Activate(); TopMost = false; } catch (Exception) { }
  }

  async void CheckSignedIn() {
    if (signedIn || checking || view.CoreWebView2 == null) return;
    checking = true;
    try {
      Uri uri;
      if (!Uri.TryCreate(view.CoreWebView2.Source ?? "", UriKind.Absolute, out uri) || !ClaudeNiangWeb.IsClaudeHost(uri.AbsoluteUri)) return;
      string path = uri.AbsolutePath.ToLowerInvariant();
      if (path.StartsWith("/login") || path.StartsWith("/logout") || path.StartsWith("/magic-link") || path.StartsWith("/sso")) return;
      List<CoreWebView2Cookie> cookies = await view.CoreWebView2.CookieManager.GetCookiesAsync("https://claude.ai");
      bool session = false;
      foreach (CoreWebView2Cookie cookie in cookies) {
        if (cookie.Name == "sessionKey" && !string.IsNullOrEmpty(cookie.Value)) session = true;
      }
      if (!session || signedIn) return;
      signedIn = true;
      pollTimer.Stop();
      hint.Text = "✓ 已登录。窗口马上关闭，Claude 娘会刷新额度。";
      closeTimer.Start();
    } catch (Exception) {
    } finally {
      checking = false;
    }
  }

  protected override void OnFormClosed(FormClosedEventArgs e) {
    closeTimer.Stop();
    pollTimer.Stop();
    try { view.Dispose(); } catch (Exception) { }
    base.OnFormClosed(e);
  }
}
