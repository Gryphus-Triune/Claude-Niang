# Claude shows its main window while it is still loading. Instead of reading
# its interface (UI Automation would switch on Chromium accessibility inside
# Claude and slow it down), wait until the main window has been visible with a
# normal size for two consecutive samples about one second apart.
if(!('ClaudeHostWindow' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'claude-host.cs') -IgnoreWarnings}
function New-WidgetReadinessState {
  return [pscustomobject]@{host=[IntPtr]::Zero;ready=$false;candidate=$false;lastProbe=-1000L;desktopStarted=$false}
}
function Test-WidgetHostReady {
  param($State,[IntPtr]$HostHandle,[long]$Now,[scriptblock]$Probe={param($h)[ClaudeHostWindow]::LooksReady($h)})
  if($State.host-ne $HostHandle){$State.host=$HostHandle;$State.ready=$false;$State.candidate=$false;$State.lastProbe=$Now-1000}
  if($HostHandle-eq [IntPtr]::Zero){return $false}
  if($State.ready){return $true}
  if($Now-$State.lastProbe-lt 1000){return $false}
  $State.lastProbe=$Now
  $looksReady=[bool](& $Probe $HostHandle)
  # Require two stable samples, rather than a fixed startup delay.
  if($looksReady -and $State.candidate){$State.ready=$true}
  $State.candidate=$looksReady
  return [bool]$State.ready
}
