param([switch]$CheckOnly,[switch]$Preview,[string]$AppDir=$PSScriptRoot)
$ErrorActionPreference='Stop'
$script:appDir=$AppDir
$script:configPath=Join-Path $script:appDir 'installation.json'
if(!(Test-Path -LiteralPath $script:configPath)){throw '请先运行「安装Claude娘.cmd」。'}
$script:config=Get-Content -LiteralPath $script:configPath -Raw -Encoding UTF8 | ConvertFrom-Json
# installation.json keeps the version that was installed; the files in this folder may be newer.
$script:appVersion=[string]$script:config.version
try{$script:appVersion=[string](Get-Content -LiteralPath (Join-Path $script:appDir 'package.json') -Raw -Encoding UTF8|ConvertFrom-Json).version}catch{}
$script:dataDir=$script:config.dataDir
$null=New-Item -ItemType Directory -Path $script:dataDir -Force
. (Join-Path $script:appDir 'runtime\common.ps1')
. (Join-Path $script:appDir 'runtime\quotes.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\ui-settings.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\characters.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\character-gallery.ps1'),[Text.Encoding]::UTF8)))
. (Join-Path $script:appDir 'runtime\audio.ps1')
. (Join-Path $script:appDir 'runtime\host-layer.ps1')
. (Join-Path $script:appDir 'runtime\host-follow.ps1')
. (Join-Path $script:appDir 'runtime\host-ready.ps1')
. (Join-Path $script:appDir 'runtime\host-occlusion.ps1')
. (Join-Path $script:appDir 'runtime\supervisor-task.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\claude-extras.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\music.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\quote-layout.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\log.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\widget-settings.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\widget-placement.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\widget-bubble.ps1'),[Text.Encoding]::UTF8)))
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $script:appDir 'runtime\widget-quota.ps1'),[Text.Encoding]::UTF8)))
Initialize-WidgetQuoteLayouts $script:appDir $script:dataDir
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
Add-WidgetType -TypeName ClaudeWidgetNative -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Diagnostics;
public static class ClaudeWidgetNative {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
  public delegate void WinEventProc(IntPtr hook,uint ev,IntPtr h,int objectId,int childId,uint threadId,uint time);
  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint first,uint last,IntPtr module,WinEventProc callback,uint processId,uint threadId,uint flags);
  [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
  public static IntPtr Hook(uint first,uint last,WinEventProc callback){return SetWinEventHook(first,last,IntPtr.Zero,callback,0,0,2);}
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int z,uint flags);
  [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h,int i);
  [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h,int i,IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h,int attr,out Rect r,int size);
  public static Rect Frame(IntPtr h){Rect r; if(DwmGetWindowAttribute(h,9,out r,16)!=0)GetWindowRect(h,out r); return r;}
  public static int ProcessId(IntPtr h){uint p;GetWindowThreadProcessId(h,out p);return (int)p;}
  public static string Title(IntPtr h){var b=new StringBuilder(256);GetWindowText(h,b,256);return b.ToString();}
}
'@
Add-WidgetType -TypeName ClaudeBezierEase -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Media.Animation;
public sealed class ClaudeBezierEase:EasingFunctionBase {
  public double X1=0.25,Y1=0.1,X2=0.25,Y2=1;
  static double Curve(double t,double a,double b){double u=1-t;return 3*u*u*t*a+3*u*t*t*b+t*t*t;}
  protected override double EaseInCore(double time){
    double low=0,high=1,t=time;
    for(int i=0;i<20;i++){t=(low+high)/2;if(Curve(t,X1,X2)<time)low=t;else high=t;}
    return Curve(t,Y1,Y2);
  }
  protected override Freezable CreateInstanceCore(){return new ClaudeBezierEase{X1=X1,Y1=Y1,X2=X2,Y2=Y2};}
}
'@ -ReferencedAssemblies ([Windows.Media.Animation.EasingFunctionBase].Assembly.Location),([Windows.Freezable].Assembly.Location)
try{
  [ClaudeWidgetNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
  # PowerShell may already have a process DPI context. Set the UI thread too,
  # so DWM, GetWindowRect and SetWindowPos all use physical screen pixels.
  [ClaudeWidgetNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
}catch{}
$script:window=[Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath (Join-Path $script:appDir 'widget.xaml') -Raw -Encoding UTF8))
# Capture the unscaled XAML canvas before native resizing changes Window.Width/Height.
$script:designWidth=[double]$script:window.FindName('AnimationStage').Width
$script:designHeight=[double]$script:window.FindName('AnimationStage').Height
$script:ui=@{}
foreach($name in @('Root','Bubble','Tail','TailNear','SceneText','QuotaText','QuoteText','BubbleShape','Girl','PressScale','FacingScale','TextFacingScale','Header','Refresh','MenuButton','Status','LiveDot','ShortRow','WeekRow','ShortLabel','WeekLabel','ShortUsed','ShortLeft','ShortReset','ShortBar','WeekUsed','WeekLeft','WeekReset','WeekBar')){$script:ui[$name]=$script:window.FindName($name)}
$script:characterId='claude-niang';$script:activeCharacter=$null
$script:status=$null
$script:statusStamp=0
$script:offsetRight=0.0;$script:offsetBottom=0.0;$script:offsetLeft=$null;$script:anchor='right';$script:side='right';$script:scale=1.0;$script:bubbleScale=1.0;$script:collapsed=$true
$script:soundOn=$true;$script:soundVolume=0.9;$script:bubbleTapAdvance=$false;$script:hideMenu=$false
$script:followHost=$true;$script:desktopTopmost=$false;$script:desktopLeft=$null;$script:desktopTop=$null;$script:desktopPositionPending=$false
$script:hostReadiness=New-WidgetReadinessState
$script:bubbleMode='quota';$script:sceneStartedAt=0;$script:sceneDeadline=0;$script:sceneTimer=$null;$script:sceneRevision=0
$script:resetTimeMode='countdown';$script:resetPhaseTimer=$null
$script:displayRequestToken=$null
$script:settingsFile=Join-Path $script:dataDir 'settings.json'
$script:settingsLoadFailed=$false
try{$settings=Get-Content -LiteralPath $script:settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json;Import-WidgetSettings $settings}
catch{
  $script:settingsLoadFailed=$true
  # A missing file is a first start. An unreadable one is left untouched: startup
  # then skips Save-Settings, so the user's only copy is not replaced by defaults.
  if(Test-Path -LiteralPath $script:settingsFile){Write-WidgetLog $script:dataDir 'widget' ('设置文件无法读取，本次使用默认设置，原文件保持不变：'+$_.Exception.Message)}
}
Initialize-WidgetAutoQuoteSettings $settings
Initialize-WidgetClaudeSettings $settings
function Set-WidgetCharacter([string]$Id,[switch]$NoSave) {
  if($script:widgetMusic -and $script:widgetMusic.Enabled){Stop-WidgetMusic}
  $character=Get-WidgetCharacter $script:appDir $script:dataDir $Id
  # Decode and build the click-through map before replacing the current pose.
  $image=Read-WidgetCharacterImage $character.path
  $alpha=[Windows.Media.Imaging.FormatConvertedBitmap]::new($image,[Windows.Media.PixelFormats]::Bgra32,$null,0)
  $alpha.Freeze();$stride=$image.PixelWidth*4;$pixels=New-Object byte[] ($stride*$image.PixelHeight)
  $alpha.CopyPixels($pixels,$stride,0)
  $previous=@{bitmap=$script:bitmap;alpha=$script:alphaBitmap;stride=$script:alphaStride;pixels=$script:alphaPixels;id=$script:characterId;character=$script:activeCharacter}
  try{
    $script:bitmap=$image;$script:alphaBitmap=$alpha;$script:alphaStride=$stride;$script:alphaPixels=$pixels
    $script:characterId=$character.id;$script:activeCharacter=$character;$script:ui.Girl.Source=$image
    if(!$NoSave){Save-Settings}
  }catch{
    $script:bitmap=$previous.bitmap;$script:alphaBitmap=$previous.alpha;$script:alphaStride=$previous.stride;$script:alphaPixels=$previous.pixels
    $script:characterId=$previous.id;$script:activeCharacter=$previous.character;$script:ui.Girl.Source=$previous.bitmap
    throw
  }
  if($script:settingsMenuUi){Update-WidgetSettingsMenu}
  return $character
}
try{$null=Set-WidgetCharacter $script:characterId -NoSave}
catch{
  $script:characterLoadNotice='上次使用的图片无法读取，已恢复默认形象。'
  try{$null=Set-WidgetCharacter 'claude-niang' -NoSave}
  catch{throw '默认形象图片 assets\claude-niang.png 无法读取，请重新完整解压程序文件夹。'}
}
# Asks the worker for a fresh read over its pipe, which it answers at once; the
# refresh.flag file, checked once a second, remains the fallback. The pipe name
# must match workerEndpoint() in runtime/shared.mjs.
function Get-WidgetWorkerPipeName {
  if(!$script:workerPipeName){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($script:dataDir).ToLowerInvariant())))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $script:workerPipeName='claude-niang-usage-'+$hash.Substring(0,32)
  }
  return $script:workerPipeName
}
function Send-WidgetPipeRefresh {
  $pipe=$null
  try{
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',(Get-WidgetWorkerPipeName),[IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(200)
    $bytes=[Text.Encoding]::UTF8.GetBytes('{"id":"'+[Guid]::NewGuid().ToString()+'","method":"refresh"}'+"`n")
    $pipe.Write($bytes,0,$bytes.Length);$pipe.Flush()
    return $true
  }catch{return $false}finally{if($pipe){$pipe.Dispose()}}
}
function Request-Refresh {
  if(Send-WidgetPipeRefresh){return}
  Write-WidgetJson -NoBackup (Join-Path $script:dataDir 'refresh.flag') @{id=[Guid]::NewGuid().ToString('N');at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();reason='user'}
}
function Exit-WidgetForSession {
  if($script:followHost){Set-WidgetSupervisorPause -AppDir $script:appDir -HostHandle $script:hostHandle.ToInt64() -HostPid ([ClaudeWidgetNative]::ProcessId($script:hostHandle))}
  else{Write-WidgetSupervisorJson (Join-Path $script:dataDir 'supervisor-pause.json') @{desktop=$true;at=[DateTime]::UtcNow.ToString('o')}}
  $script:window.Close()
}
function Set-MenuVisible([bool]$show){
  $show=$show -and !$script:hideMenu
  $script:ui.MenuButton.Opacity=if($show){1}else{0};$script:ui.MenuButton.IsHitTestVisible=$show
}
function Test-GirlAlpha([Windows.Point]$rootPoint){
  $point=$script:ui.Root.TranslatePoint($rootPoint,$script:ui.Girl)
  $fit=[Math]::Min($script:ui.Girl.ActualWidth/$script:bitmap.PixelWidth,$script:ui.Girl.ActualHeight/$script:bitmap.PixelHeight)
  if($fit-le 0){return $false}
  $x=[int][Math]::Floor(($point.X-($script:ui.Girl.ActualWidth-$script:bitmap.PixelWidth*$fit)/2)/$fit)
  $y=[int][Math]::Floor(($point.Y-($script:ui.Girl.ActualHeight-$script:bitmap.PixelHeight*$fit)/2)/$fit)
  if($x-lt 0 -or $y-lt 0 -or $x-ge $script:bitmap.PixelWidth -or $y-ge $script:bitmap.PixelHeight){return $false}
  return $script:alphaPixels[$y*$script:alphaStride+$x*4+3]-gt 10
}
function Test-WidgetHit([Windows.Point]$rootPoint){
  $hit=$script:ui.Root.InputHitTest($rootPoint)
  if(!$hit){return $false}
  if($hit-eq $script:ui.Girl){return Test-GirlAlpha $rootPoint}
  return $true
}
Set-Appearance;Set-BubbleState;Update-Quota
if($CheckOnly){$hostWindow=[ClaudeHostWindow]::Find();$foregroundWindow=[ClaudeWidgetNative]::GetAncestor([ClaudeWidgetNative]::GetForegroundWindow(),2);@{ok=$true;imageLoaded=$script:bitmap.PixelWidth-gt 0;characterId=$script:characterId;characterName=$script:activeCharacter.name;soundVolume=$script:soundVolume;sizing=@{character=$script:scale;bubble=$script:bubbleScale;display=$script:displayScale};autoQuotes=@{enabled=$script:autoQuoteEnabled;intervalSeconds=$script:autoQuoteIntervalSeconds};placement=@{right=$script:offsetRight;left=$script:offsetLeft;bottom=$script:offsetBottom};host=$hostWindow.ToInt64();hostTitle=[ClaudeWidgetNative]::Title($hostWindow);foreground=$foregroundWindow.ToInt64();foregroundTitle=[ClaudeWidgetNative]::Title($foregroundWindow);dataDir=$script:dataDir}|ConvertTo-Json;return}
if($Preview){
  $script:collapsed=$false;Set-Appearance;Set-BubbleState;Apply-Scene
  $script:ui.Root.LayoutTransform=[Windows.Media.Transform]::Identity
  $root=$script:window.FindName('AnimationStage');$root.Measure([Windows.Size]::new($script:designWidth,$script:designHeight));$root.Arrange([Windows.Rect]::new(0,0,$script:designWidth,$script:designHeight));$root.UpdateLayout()
  $render=New-Object Windows.Media.Imaging.RenderTargetBitmap($script:designWidth,$script:designHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
  $render.Render($root);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
  $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
  $stream=[IO.File]::Create((Join-Path $script:appDir 'preview.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()};return
}
$mutexKey='Local\ClaudeNiang_'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:appDir))).Replace('/','_').Replace('+','-')
$script:mutex=[Threading.Mutex]::new($false,$mutexKey);$script:mutexOwned=$false
try{$script:mutexOwned=$script:mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$script:mutexOwned=$true}
if(!$script:mutexOwned){$script:mutex.Dispose();return}
Initialize-WidgetAudio -AppDir $script:appDir -DataDir $script:dataDir
# A stop request written while this GUI was still starting must win. Only a
# recent flag is honoured (stale leftovers are removed); the flag is removed
# after honoring so a later manual start is not blocked.
$stopFlag=Join-Path $script:dataDir 'stop.flag'
if([IO.File]::Exists($stopFlag)){
  $stopAge=([DateTime]::UtcNow-[IO.File]::GetLastWriteTimeUtc($stopFlag)).TotalSeconds
  if($stopAge-ge 0 -and $stopAge-lt 30){
    Remove-Item -LiteralPath $stopFlag -ErrorAction SilentlyContinue
    $script:mutex.Dispose();return
  }
}
Remove-Item -LiteralPath $stopFlag -ErrorAction SilentlyContinue
Write-WidgetLog $script:dataDir 'widget' ('挂件启动（'+$script:appVersion+'）')
$script:worker=$null
$script:lastSupervisorProbe=0;$script:lastSupervisorStart=$null;$script:userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:lastWorkerProbe=$null;$script:lastWorkerStart=$null;$script:workerMark=$null;$script:workerMisses=0;$script:workerClock=[Diagnostics.Stopwatch]::StartNew();$script:runtimeClosed=$false
$script:hostHandle=[ClaudeHostWindow]::Find();$script:lastPresence=0;$script:lastHostProbe=0;$script:drag=$null
$script:lastPresenceKey='';$script:lastPresenceWrite=0
$script:lastForeground=[IntPtr](-1);$script:foregroundHost=[IntPtr]::Zero
$script:lastPosition=$null;$script:attachedHost=[IntPtr]::Zero;$script:updating=$false
$interop=New-Object Windows.Interop.WindowInteropHelper($script:window)
$script:widgetHandle=$interop.EnsureHandle()
$script:occlusionRecovery=[ClaudeWidgetOcclusionRecovery]::new($script:widgetHandle)
$script:hostFollower=[ClaudeWidgetHostFollower]::new($script:widgetHandle)
$script:hostFollower.LayoutRequested=[Action]{if(!$script:hostEventTimer.IsEnabled){$script:hostEventTimer.Start()}}
$ex=[ClaudeWidgetNative]::GetWindowLongPtr($script:widgetHandle,-20).ToInt64()
[ClaudeWidgetNative]::SetWindowLongPtr($script:widgetHandle,-20,[IntPtr]($ex-bor 0x08000000-bor 0x80))|Out-Null
$source=[Windows.Interop.HwndSource]::FromHwnd($script:widgetHandle)
$script:messageHook=[Windows.Interop.HwndSourceHook]{param($hwnd,$msg,$w,$l,[ref]$handled)
  if($msg-eq 0x47){$script:occlusionRecovery.OnPositionChanged($l)}
  if($msg-eq 0x02E0 -or $msg-eq 0x007E -or $msg-eq 0x001A){
    $script:lastPosition=$null
    if($script:hostEventTimer -and !$script:hostEventTimer.IsEnabled){$script:hostEventTimer.Start()}
  }
  if($msg-eq 0x84 -and !$script:drag){
    $packed=$l.ToInt64();$x=[int]($packed-band 65535);$y=[int](($packed-shr 16)-band 65535)
    if($x-ge 32768){$x-=65536};if($y-ge 32768){$y-=65536}
    $point=$script:ui.Root.PointFromScreen([Windows.Point]::new($x,$y))
    if(!(Test-WidgetHit $point)){$handled.Value=$true;return [IntPtr](-1)}
  }
  if($msg-eq 0x21){$handled.Value=$true;return [IntPtr]3};return [IntPtr]::Zero
}
$source.AddHook($script:messageHook)
Initialize-WidgetSettingsMenu
$script:ui.Refresh.Add_Click({param($sender,$event)Request-Refresh;Restart-SceneTtl;$script:ui.Status.Text='正在刷新额度…';$event.Handled=$true})
$script:ui.MenuButton.Add_Click({Open-WidgetMenu})
$script:menuTimer=New-Object Windows.Threading.DispatcherTimer
$script:menuTimer.Interval=[TimeSpan]::FromMilliseconds(180)
$script:menuTimer.Add_Tick({
  $script:menuTimer.Stop()
  if(!$script:ui.Girl.IsMouseOver -and !$script:ui.MenuButton.IsMouseOver -and !$script:context.IsOpen){Set-MenuVisible $false}
})
foreach($control in @($script:ui.Girl,$script:ui.MenuButton)){
  $control.Add_MouseEnter({$script:menuTimer.Stop();Set-MenuVisible $true})
  $control.Add_MouseLeave({$script:menuTimer.Start()})
}
$script:context.Add_Closed({$script:menuTimer.Start()})
foreach($control in @($script:ui.Bubble,$script:ui.Tail,$script:ui.TailNear)){$control.Add_MouseLeftButtonUp({param($sender,$event)Next-Bubble;$event.Handled=$true})}
$pressDown={param($sender,$event)
  Reset-WidgetAutoQuoteSchedule
  $cursor=New-Object ClaudeWidgetNative+Point;[ClaudeWidgetNative]::GetCursorPos([ref]$cursor)|Out-Null
  $rect=New-Object ClaudeWidgetNative+Rect;[ClaudeWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$rect)|Out-Null
  if(Test-WidgetMusicActive){
    Hide-Quota
    $script:drag=@{music=$true;control=$sender;moved=$false}
    $script:widgetMusic.BeginHold($cursor.X,$cursor.Y)
    $sender.CaptureMouse()|Out-Null;Play-WidgetPressSound;$event.Handled=$true;return
  }
  $script:hostFollower.Suspend()
  $script:drag=@{x=$cursor.X;y=$cursor.Y;left=$rect.Left;top=$rect.Top;moved=$false;control=$sender}
  $sender.CaptureMouse()|Out-Null;Animate-Press $true;Play-WidgetPressSound;$event.Handled=$true
}
$pressMove={param($sender,$event)
  if(!$script:drag){return}
  if($script:drag.music){$event.Handled=$true;return}
  $cursor=New-Object ClaudeWidgetNative+Point;[ClaudeWidgetNative]::GetCursorPos([ref]$cursor)|Out-Null
  $dx=$cursor.X-$script:drag.x;$dy=$cursor.Y-$script:drag.y
  if($dx*$dx+$dy*$dy-lt 9 -and !$script:drag.moved){return}
  if(Test-WidgetMusicActive){
    Stop-WidgetMusic -KeepPosition
    $musicRect=New-Object ClaudeWidgetNative+Rect;[ClaudeWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$musicRect)|Out-Null
    $script:drag.left=$musicRect.Left;$script:drag.top=$musicRect.Top
  }
  $script:drag.moved=$true
  if($script:followHost -and $script:hostHandle-eq [IntPtr]::Zero){return}
  if(!$script:followHost){$script:desktopLeft=$script:drag.left+$dx;$script:desktopTop=$script:drag.top+$dy}
  $frame=Get-WidgetPlacementFrame;$dpi=Get-WidgetPlacementDpi
  if($dpi-le 0){$dpi=1}
  if(!(Test-WidgetPlacementFrame $frame $dpi)){return}
  $null=Set-WidgetPixelSize $dpi
  $w=[int]($script:designWidth*$script:displayScale*$dpi);$h=[int]($script:designHeight*$script:displayScale*$dpi)
  $x=[int]($script:drag.left+$dx)
  $y=Limit-WidgetVerticalPosition $frame $dpi ($script:drag.top+$dy)
  $nextSide=if($cursor.X-lt ($frame.Left+$frame.Right)/2){'left'}else{'right'}
  if($nextSide-ne $script:side){
    $before=$null
    if($script:ui.Girl){$center=[Windows.Point]::new($script:ui.Girl.ActualWidth/2,$script:ui.Girl.ActualHeight/2);$before=$script:ui.Girl.PointToScreen($center)}
    $script:side=$nextSide;Set-Facing
    if($before){
      # Mirroring the whole canvas must not teleport the character. Rebase
      # this drag as well, so the next mouse move keeps the same grab offset.
      $after=$script:ui.Girl.PointToScreen($center);$shift=[int][Math]::Round($before.X-$after.X)
      $x+=$shift;$script:drag.left+=$shift
    }
  }
  $x=Limit-WidgetHorizontalPosition $frame $dpi $x
  [ClaudeWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr]::Zero,$x,$y,0,0,0x15)|Out-Null
  $script:lastPosition=$null
  if($script:followHost){
    $script:offsetRight=($frame.Right-$x-$w)/$dpi;$script:offsetBottom=($frame.Bottom-$y-$h)/$dpi
    $script:offsetLeft=($x-$frame.Left)/$dpi;$script:anchor='free'
  }else{$script:desktopLeft=$x;$script:desktopTop=$y}
}
$pressUp={param($sender,$event)
  if(!$script:drag){return}
  Reset-WidgetAutoQuoteSchedule
  if($script:drag.music){
    $script:drag=$null
    $sender.ReleaseMouseCapture()
    if(Test-WidgetMusicActive){$script:widgetMusic.EndHold()}
    Play-WidgetReleaseSound
    $script:hostEventTimer.Start();$event.Handled=$true;return
  }
  $moved=$script:drag.moved;$script:drag=$null;$sender.ReleaseMouseCapture()
  Animate-Press $false
  Play-WidgetReleaseSound
  if(!$moved){Click-Character}
  elseif($script:followHost -and $script:side-eq 'left' -and $script:offsetLeft-ge 0 -and $script:offsetLeft-le 18){$script:anchor='left';$script:offsetLeft=0;$script:side='left';Set-Facing}
  elseif($script:followHost -and $script:side-eq 'right' -and $script:offsetRight-ge 0 -and $script:offsetRight-le 18){$script:anchor='right';$script:offsetRight=0;$script:side='right';Set-Facing}
  Save-Settings;$script:hostEventTimer.Start();$event.Handled=$true
}
$script:ui.Girl.Add_MouseLeftButtonDown($pressDown);$script:ui.Girl.Add_MouseMove($pressMove);$script:ui.Girl.Add_MouseLeftButtonUp($pressUp)
$script:ui.Girl.Add_LostMouseCapture({
  if($script:drag -and $script:drag.music){
    Reset-WidgetAutoQuoteSchedule;$script:drag=$null
    if(Test-WidgetMusicActive){$script:widgetMusic.EndHold()}
    Stop-WidgetAudio;$script:hostEventTimer.Start();return
  }
  if($script:drag){Reset-WidgetAutoQuoteSchedule;$script:drag=$null;Animate-Press $false;Stop-WidgetAudio;Save-Settings;$script:hostEventTimer.Start()}
})
# Liveness of the quota worker. Progress is judged by the heartbeat counter it
# writes (seq), never by comparing the two processes' clocks: a system time
# adjustment once made a working worker look stuck and get killed. Returns
# alive=$true, $false (gone, or the files belong to another process) or $null
# (cannot tell this time: a read raced a write, or no progress since last probe).
function Get-WidgetWorkerHealth {
  $file=Join-Path $script:dataDir 'worker-status.json'
  if(![IO.File]::Exists($file)){return @{alive=$false;reason='没有状态文件'}}
  try{
    $health=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
    $owner=Get-Content -LiteralPath (Join-Path $script:dataDir 'worker.lock') -Raw -Encoding UTF8|ConvertFrom-Json
  }catch{return @{alive=$null;reason=('状态文件读取失败：'+$_.Exception.Message)}}
  if(!$health.token -or $health.token-ne $owner.token -or $health.pid-ne $owner.pid){return @{alive=$false;reason='状态文件与锁文件不一致'}}
  $process=Get-Process -Id ([int]$health.pid) -ErrorAction SilentlyContinue
  if(!$process){return @{alive=$false;reason='进程已退出'}}
  $ours=$null
  try{$ours=$process.Path-eq $script:config.nodePath -and $process.StartTime.ToUniversalTime()-le [DateTimeOffset]::FromUnixTimeMilliseconds([long]$health.startedAt).UtcDateTime}catch{}finally{$process.Dispose()}
  if($ours-eq $false){return @{alive=$false;reason='进程号已属于其他程序'}}
  if($null-eq $health.seq){
    # A worker from before the heartbeat counter: fall back to its timestamp.
    $age=[Math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-[long]$health.at)
    if($age-lt 5000){return @{alive=$true;mark=('at#'+$health.at)}}
    return @{alive=$null;reason=('状态 '+[int]($age/1000)+' 秒未更新')}
  }
  $mark=[string]$health.token+'#'+[string]$health.seq
  if($mark-ne $script:workerMark){return @{alive=$true;mark=$mark}}
  return @{alive=$null;reason='心跳没有前进'}
}
function Ensure-QuotaWorker([long]$now){
  # Intervals use the widget's own monotonic clock, not the system time.
  $clock=$script:workerClock.ElapsedMilliseconds
  if($null-ne $script:lastWorkerProbe -and $clock-$script:lastWorkerProbe-lt 5000){return}
  $script:lastWorkerProbe=$clock
  $health=Get-WidgetWorkerHealth
  if($health.alive){$script:workerMark=$health.mark;$script:workerMisses=0;return}
  # A gone worker is replaced at once; an unclear one gets a second probe first.
  if($null-eq $health.alive){$script:workerMisses++;if($script:workerMisses-lt 2){return}}
  $script:workerMisses=0
  if($script:worker){
    try{
      if(!$script:worker.HasExited){
        if($null-ne $script:lastWorkerStart -and $clock-$script:lastWorkerStart-lt 10000){return}
        $script:worker.Kill()
        if(!$script:worker.WaitForExit(1000)){return}
      }
    }catch{}
    $script:worker.Dispose();$script:worker=$null
  }
  if($null-ne $script:lastWorkerStart -and $clock-$script:lastWorkerStart-lt 5000){return}
  # The first start comes with the widget; any later one replaces a worker that
  # exited or stopped answering, and the log says which.
  if($null-ne $script:lastWorkerStart){Write-WidgetLog $script:dataDir 'widget' ('后台进程没有响应（'+$health.reason+'），重新启动')}
  $script:lastWorkerStart=$clock
  $workerArgs=@(('"'+(Join-Path $script:appDir 'runtime\watch.mjs')+'"'),('"'+$script:configPath+'"'),[string]$PID)
  try{$script:worker=Start-Process -FilePath $script:config.nodePath -ArgumentList $workerArgs -WindowStyle Hidden -PassThru}
  catch{Write-WidgetLog $script:dataDir 'widget' ('后台进程启动失败：'+$_.Exception.Message)}
}
# The supervisor brings the widget back whenever Claude restarts. It runs from
# sign-in to sign-out; if it is gone while the widget still runs (ended from Task
# Manager, say), start it again, at most every five minutes. It holds a named
# mutex while it runs, which is cheap to look for. A stop or disable request
# (停用, reinstalling) is left alone.
function Ensure-WidgetSupervisor {
  $clock=$script:workerClock.ElapsedMilliseconds
  if($clock-$script:lastSupervisorProbe-lt 30000){return}
  $script:lastSupervisorProbe=$clock
  $mutex=$null
  if([Threading.Mutex]::TryOpenExisting('Local\ClaudeNiangSupervisor-'+$script:userSid,[ref]$mutex)){$mutex.Dispose();return}
  foreach($flag in @('supervisor-stop.flag','supervisor-disabled.flag')){if(Test-Path -LiteralPath (Join-Path $script:dataDir $flag)){return}}
  if($null-ne $script:lastSupervisorStart -and $clock-$script:lastSupervisorStart-lt 300000){return}
  $script:lastSupervisorStart=$clock
  Write-WidgetLog $script:dataDir 'widget' '监督进程不在运行，重新启动'
  $starter=Join-Path $script:appDir 'runtime\start-supervisor.ps1';$launcher=Join-Path $script:appDir 'runtime\claude-niang-launcher.exe'
  try{Start-Process -FilePath $launcher -ArgumentList 'open' -WindowStyle Hidden -ErrorAction Stop}
  catch{
    try{Start-Process -FilePath (Get-WidgetPowerShellPath) -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$starter+'"')) -WindowStyle Hidden -ErrorAction Stop}
    catch{Write-WidgetLog $script:dataDir 'widget' ('监督进程无法启动：'+$_.Exception.Message)}
  }
}
function Stop-WidgetRuntime {
  if($script:runtimeClosed){return};$script:runtimeClosed=$true
  Write-WidgetLog $script:dataDir 'widget' '挂件退出'
  try{if($script:occlusionRecovery){$script:occlusionRecovery.Dispose()}}catch{}
  try{Stop-WidgetMusic}catch{}
  try{if($script:hostFollower){$script:hostFollower.Dispose()}}catch{}
  foreach($timer in @($script:settingsMenuDismissTimer,$script:timer,$script:hostEventTimer,$script:menuTimer,$script:sceneTimer,$script:resetPhaseTimer,$script:closeTimer)){try{if($timer){$timer.Stop()}}catch{}}
  try{Close-WidgetAudio}catch{}
  foreach($hook in $script:eventHooks){try{if($hook-ne [IntPtr]::Zero){[ClaudeWidgetNative]::UnhookWinEvent($hook)|Out-Null}}catch{}}
  if($script:worker){try{if(!$script:worker.HasExited){$script:worker.Kill()}}catch{}; $script:worker.Dispose();$script:worker=$null}
  foreach($name in @('runtime.json','presence.json')){
    $file=Join-Path $script:dataDir $name
    try{$state=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json;if($state.pid-eq $PID){Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue}}catch{}
  }
  # A consumed stop request must not linger: the next normal launch should not
  # be swallowed by an old flag.
  try{Remove-Item -LiteralPath (Join-Path $script:dataDir 'stop.flag') -ErrorAction SilentlyContinue}catch{}
  try{if($script:mutexOwned){$script:mutex.ReleaseMutex();$script:mutexOwned=$false}}catch{};try{$script:mutex.Dispose()}catch{}
}
function Write-WidgetPresence([bool]$visible,[long]$now){
  # The worker counts presence.json younger than 5 seconds as a visible widget;
  # the rest is for diagnosis. Rewrite it when visibility, host, bubble or
  # character change, otherwise every 2.5 seconds instead of every second.
  $key=@($visible,$script:hostHandle,$script:collapsed,$script:bubbleMode,$script:characterId)-join '|'
  if($key-eq $script:lastPresenceKey -and $now-$script:lastPresenceWrite-ge 0 -and $now-$script:lastPresenceWrite-lt 2500){return}
  $script:lastPresenceKey=$key;$script:lastPresenceWrite=$now
  Write-WidgetJson -NoBackup (Join-Path $script:dataDir 'presence.json') @{visible=[bool]$visible;at=$now;host=$script:hostHandle.ToInt64();widget=$script:widgetHandle.ToInt64();pid=$PID;character=@{id=$script:characterId;name=$script:activeCharacter.name;galleryOpen=[bool]($script:characterGallery -and $script:characterGallery.IsVisible)};sound=(Get-WidgetAudioStatus);followHost=$script:followHost;follow=@{ready=$script:hostFollower.Ready;events=$script:hostFollower.MovementEvents;mode='native-immediate';animationPaddingDip=14};sizing=@{character=$script:scale;bubble=$script:bubbleScale;display=$script:displayScale;preview=[bool]$script:settingsSizePreview};autoQuotes=@{enabled=$script:autoQuoteEnabled;intervalSeconds=$script:autoQuoteIntervalSeconds;nextAt=$script:autoQuoteNextAt;displayCount=$script:autoQuoteDisplayCount};recovery=@{checks=$script:occlusionRecovery.Checks;toggles=$script:occlusionRecovery.Toggles;pending=$script:occlusionRecovery.Pending;cloaked=$script:occlusionRecovery.OwnedCloak;failed=$script:occlusionRecovery.Failed;hresult=$script:occlusionRecovery.LastHresult};music=(Get-WidgetMusicStatus);scene=@{open=!$script:collapsed;mode=$script:bubbleMode;resetTimeMode=$script:resetTimeMode;startedAt=$script:sceneStartedAt;closesAt=$script:sceneDeadline;shortReset=$script:ui.ShortReset.Text;weekReset=$script:ui.WeekReset.Text}}
}
function Tick-Widget {
  if($script:updating){return}
  $script:updating=$true
  try{
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Tick-Scene $now
  if($now-$script:lastPresence-ge 1000 -and (Test-Path -LiteralPath (Join-Path $script:dataDir 'stop.flag'))){$script:window.Close();return}
  Ensure-QuotaWorker $now
  Ensure-WidgetSupervisor
  $foreground=[ClaudeWidgetNative]::GetAncestor([ClaudeWidgetNative]::GetForegroundWindow(),2)
  if($foreground-ne $script:lastForeground -or ($script:hostHandle-ne [IntPtr]::Zero -and ![ClaudeWidgetNative]::IsWindow($script:hostHandle))){
    $script:lastForeground=$foreground
    $script:foregroundHost=[ClaudeHostWindow]::ForegroundHost($foreground)
    if($script:foregroundHost-ne [IntPtr]::Zero){$script:hostHandle=$script:foregroundHost;$script:lastPosition=$null}
    elseif($script:hostHandle-eq [IntPtr]::Zero -or ![ClaudeWidgetNative]::IsWindow($script:hostHandle)){$script:hostHandle=[IntPtr]::Zero;$script:lastHostProbe=0;$script:lastPosition=$null}
  }
  if($script:hostHandle-eq [IntPtr]::Zero -and $now-$script:lastHostProbe-gt 1000){$script:hostHandle=[ClaudeHostWindow]::Find();$script:lastHostProbe=$now}
  $hostVisible=$script:hostHandle-ne [IntPtr]::Zero -and [ClaudeWidgetZOrderNative]::VisibleSurface($script:hostHandle) -and ![ClaudeWidgetNative]::IsIconic($script:hostHandle)
  $hostReady=Test-WidgetHostReady $script:hostReadiness $script:hostHandle $now
  if(!$script:followHost -and !$script:hostReadiness.desktopStarted -and ($script:hostHandle-eq [IntPtr]::Zero -or ($hostVisible -and $hostReady))){$script:hostReadiness.desktopStarted=$true}
  $visible=if($script:followHost){$hostVisible -and $hostReady}else{$script:hostReadiness.desktopStarted}
  $placementFrame=if($visible){Get-WidgetPlacementFrame}else{$null}
  $placementDpi=if($visible){Get-WidgetPlacementDpi}else{1}
  $visible=$visible -and (Test-WidgetPlacementFrame $placementFrame $placementDpi)
  if($visible){
    if($script:attachedHost-ne $script:hostHandle){
      $script:attachedHost=$script:hostHandle;$script:lastPosition=$null
    }
    $showWidget=!$script:window.IsVisible
    if(!$script:drag){
      $frame=$placementFrame;$dpi=$placementDpi
      if($dpi-le 0){$dpi=1}
      $fitted=Get-WidgetLayoutScale
      if(!$script:followHost){$fitted=[Math]::Min($fitted,[Math]::Min(($frame.Right-$frame.Left)/$dpi/$script:designWidth,($frame.Bottom-$frame.Top)/$dpi/$script:designHeight))}
      if([Math]::Abs($script:displayScale-$fitted)-gt 0.001){Set-Appearance}
      $null=Set-WidgetPixelSize $dpi
      $w=[int]($script:designWidth*$script:displayScale*$dpi);$h=[int]($script:designHeight*$script:displayScale*$dpi)
      if(!$script:followHost){
        if($null-eq $script:desktopLeft){$script:desktopLeft=$frame.Right-$w-24;$script:desktopTop=$frame.Bottom-$h-24}
        $x=[int]$script:desktopLeft
      }
      elseif($script:anchor-eq 'left'){$x=[int]($frame.Left+$script:offsetLeft*$dpi)}
      elseif($script:anchor-eq 'free'){
        if($null-eq $script:offsetLeft){$script:offsetLeft=[Math]::Max(0,($frame.Right-$frame.Left-$w)/$dpi-$script:offsetRight)}
        $x=[int]($frame.Left+$script:offsetLeft*$dpi)
      }else{$x=[int]($frame.Right-$w-$script:offsetRight*$dpi)}
      $desiredY=if($script:followHost){$frame.Bottom-$h-$script:offsetBottom*$dpi}else{$script:desktopTop}
      $y=[int]$desiredY
      # A smaller host must not clip away a saved free-position character.
      # Clamp to the full host frame, not the monitor, and retain saved offsets
      # so growing the host restores the user's requested relative position.
      $desktopCoordinatesReady=$script:followHost
      if(!$script:followHost){
        $desktopCoordinatesReady=Test-WidgetDesktopCoordinates
      }
      if($script:followHost){
        # Layout coordinates also work before the first Show; PointToScreen
        # requires a connected visual tree and cannot be used at startup.
        $characterBounds=Get-WidgetCharacterPixelBounds $dpi
        $minimum=$frame.Left-$characterBounds[0];$maximum=$frame.Right-$characterBounds[2]
        $x=if($maximum-lt $minimum){[int][Math]::Round(($minimum+$maximum)/2)}else{[Math]::Max($minimum,[Math]::Min($maximum,$x))}
        $y=[Math]::Max(($frame.Top-$characterBounds[1]),[Math]::Min(($frame.Bottom-$characterBounds[3]),$y))
      }elseif($desktopCoordinatesReady){
        $x=Limit-WidgetHorizontalPosition $frame $dpi $x
        $y=Limit-WidgetVerticalPosition $frame $dpi $desiredY
      }else{$script:desktopPositionPending=$true}
      $position="$($script:hostHandle):$x,$y,$w,$h"
      $forceDesktopPosition=(!$script:followHost -and $desktopCoordinatesReady -and $script:desktopPositionPending)
      if(($script:followHost-or $desktopCoordinatesReady) -and ($position-ne $script:lastPosition -or $forceDesktopPosition) -and !(Test-WidgetMusicActive)){
        [ClaudeWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr]::Zero,$x,$y,0,0,0x15)|Out-Null
        $script:lastPosition=$position
        if($forceDesktopPosition){$script:desktopPositionPending=$false}
        if($script:context.IsOpen){Set-WidgetMenuBounds;Position-WidgetMenuToHost}
      }
      if($script:followHost){$nativeFrame=[ClaudeWidgetNative]::Frame($script:hostHandle);$script:hostFollower.Configure($script:hostHandle,$nativeFrame.Left,$nativeFrame.Top,$nativeFrame.Right,$nativeFrame.Bottom,$w,$h,[int]($script:offsetLeft*$dpi),[int]($script:offsetRight*$dpi),[int]($script:offsetBottom*$dpi),$script:anchor,$true,$characterBounds)}
      Update-WidgetMusicPlacement $frame $dpi $x $y ([bool]$visible)
    }
    if($script:followHost){
      $musicLight=if(Test-WidgetMusicActive){$script:widgetMusic.LampHandle}else{[IntPtr]::Zero}
      if(!$script:occlusionRecovery.OwnedCloak){$layer=Set-WidgetAboveHost $script:widgetHandle $script:hostHandle $musicLight}
    }
    else{Set-WidgetDesktopLayer $script:widgetHandle $script:desktopTopmost}
    if($showWidget){
      Reset-WidgetAutoQuoteSchedule $now
      $script:window.Show()
      if(!$script:followHost){
        $script:window.UpdateLayout();$script:desktopPositionPending=$true
        if($script:hostEventTimer){$script:hostEventTimer.Start()}
      }
      $script:lastPosition=$null
    }
  }elseif($script:window.IsVisible){
    Reset-WidgetAutoQuoteSchedule $now
    $script:hostFollower.Suspend()
    $script:context.IsOpen=$false
    # Also return any owned quote editor to the normal band before hiding the overlay.
    [ClaudeWidgetNative]::SetWindowPos($script:widgetHandle,[IntPtr](-2),0,0,0,0,0x13)|Out-Null
    $script:window.Hide()
  }
  $recoverAllowed=$script:followHost -and $visible -and !$script:drag -and !$script:context.IsOpen -and !$script:settingsSizePreview -and !($script:characterGallery -and $script:characterGallery.IsVisible) -and !($script:quoteEditor -and $script:quoteEditor.IsVisible)
  if($script:occlusionRecovery){$script:occlusionRecovery.Configure($script:hostHandle,[bool]$recoverAllowed)}
  if($now-$script:lastPresence-ge 1000){
    Update-WidgetMusicVisibility ([bool]$visible) ([bool]($script:settingsSizePreview -or ($script:characterGallery -and $script:characterGallery.IsVisible) -or ($script:quoteEditor -and $script:quoteEditor.IsVisible)))
    Write-WidgetPresence ([bool]$visible) $now
    Update-Quota;$script:lastPresence=$now
    Read-DisplayRequest
    Tick-WidgetClaudeNotices ([bool]$visible)
    Tick-WidgetAutoQuote $now ([bool]$visible)
  }
  }finally{$script:updating=$false}
}
$script:winEventCallback=[ClaudeWidgetNative+WinEventProc]{param($hook,$ev,$hwnd,$objectId,$childId,$threadId,$time)
  if($objectId-eq 0 -and $childId-eq 0 -and $ev-in @(3,17,22,23,0x800A)){$script:occlusionRecovery.OnWindowEvent($hwnd)}
  if($hwnd-eq $script:hostHandle -and $objectId-eq 0 -and $childId-eq 0){
    if($ev-eq 16){$script:context.IsOpen=$false}
  }
  if($ev-eq 3 -or ($objectId-eq 0 -and $childId-eq 0 -and ($hwnd-eq $script:hostHandle -or ($script:hostHandle-eq [IntPtr]::Zero -and [ClaudeHostWindow]::IsCandidate($hwnd))))){
    # Native movement is immediate. Only lifecycle, DPI/resize and popup layout
    # need the slower PowerShell update.
    if(!$script:hostEventTimer.IsEnabled){$script:hostEventTimer.Start()}
  }
}
$script:hostEventTimer=New-Object Windows.Threading.DispatcherTimer
$script:hostEventTimer.Interval=[TimeSpan]::FromMilliseconds(33)
$script:hostEventTimer.Add_Tick({$script:hostEventTimer.Stop();try{Tick-Widget}catch{Write-WidgetLog $script:dataDir 'widget' $_}})
$script:eventHooks=@(
  [ClaudeWidgetNative]::Hook(3,3,$script:winEventCallback),
  [ClaudeWidgetNative]::Hook(16,23,$script:winEventCallback),
  [ClaudeWidgetNative]::Hook(0x8000,0x8003,$script:winEventCallback),
  [ClaudeWidgetNative]::Hook(0x800A,0x800A,$script:winEventCallback)
)
$script:timer=New-Object Windows.Threading.DispatcherTimer
$script:timer.Interval=[TimeSpan]::FromMilliseconds(1000)
$script:timer.Add_Tick({try{Tick-Widget}catch{Write-WidgetLog $script:dataDir 'widget' $_}})
$script:window.Add_Closed({
  Stop-WidgetRuntime
  [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
try{
  # Do not replace a settings file that failed to load with defaults; the
  # user's original file is the only remaining copy.
  if(!$script:settingsLoadFailed){Save-Settings}
  Ensure-QuotaWorker ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  $widgetProcess=Get-Process -Id $PID
  try{$processStartedAt=$widgetProcess.StartTime.ToUniversalTime().ToString('o')}finally{$widgetProcess.Dispose()}
  Write-WidgetJson -NoBackup (Join-Path $script:dataDir 'runtime.json') @{pid=$PID;widget=$script:widgetHandle.ToInt64();startedAt=[DateTime]::UtcNow.ToString('o');processStartedAt=$processStartedAt;eventHooks=@($script:eventHooks|ForEach-Object{$_.ToInt64()});fallbackIntervalMs=1000;movementMode='native-immediate'}
  $script:timer.Start();Tick-Widget
  [Windows.Threading.Dispatcher]::Run()
}catch{
  Write-WidgetLog $script:dataDir 'widget' ('挂件异常退出：'+$_.Exception.ToString())
  throw
}finally{Stop-WidgetRuntime}
