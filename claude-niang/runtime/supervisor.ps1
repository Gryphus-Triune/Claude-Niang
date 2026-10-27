param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')
. (Join-Path $PSScriptRoot 'log.ps1')
$appDir=Split-Path $PSScriptRoot -Parent
$info=Get-WidgetSupervisorInfo $appDir
if(!('ClaudeHostWindow' -as [type])){Add-WidgetType -TypeName ClaudeHostWindow -Path (Join-Path $PSScriptRoot 'claude-host.cs')}
if(!('ClaudeWidgetSupervisorNative' -as [type])){
Add-WidgetType -TypeName ClaudeWidgetSupervisorNative -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ClaudeWidgetSupervisorNative {
 [DllImport("user32.dll")]public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 public static int ProcessId(IntPtr h){uint value;GetWindowThreadProcessId(h,out value);return (int)value;}
}
'@
}

function Test-WidgetSupervisorPause($Pause,$Hosts){
  if(!$Pause){return $false}
  if($Pause.desktop){return $true}
  foreach($item in @($Hosts)){
    if([long]$Pause.host-gt 0 -and [long]$item.handle-eq [long]$Pause.host){
      if([int]$Pause.hostPid-gt 0 -and [int]$item.pid-ne [int]$Pause.hostPid){continue}
      if([long]$Pause.hostStarted-gt 0 -and [long]$item.started-ne [long]$Pause.hostStarted){continue}
      return $true
    }
  }
  return $false
}

# The loop reads the same few JSON files every 1.5 seconds; parse one again
# only when its time stamp or size has changed.
$script:jsonCache=@{}
function Read-WidgetCachedJson([string]$File){
  $info=[IO.FileInfo]::new($File)
  if(!$info.Exists){$script:jsonCache.Remove($File);return $null}
  $stamp=[string]$info.LastWriteTimeUtc.Ticks+':'+$info.Length
  $cached=$script:jsonCache[$File]
  if($cached -and $cached.stamp-eq $stamp){return $cached.value}
  $value=[IO.File]::ReadAllText($File,[Text.Encoding]::UTF8)|ConvertFrom-Json
  $script:jsonCache[$File]=@{stamp=$stamp;value=$value}
  return $value
}

# The full identity check (process start time, then the command line through
# WMI) is costly, so it runs once per widget process. Later rounds only confirm
# that the same window still belongs to the same process.
$script:verifiedGui=''
function Get-WidgetSupervisorRunningGui([string]$DataDir,[string]$ExpectedAppDir){
  $process=$null
  try{
    $runtime=Read-WidgetCachedJson (Join-Path $DataDir 'runtime.json')
    if(!$runtime){$script:verifiedGui='';return $false}
    $handle=[IntPtr]([long]$runtime.widget)
    if(![ClaudeWidgetSupervisorNative]::IsWindow($handle) -or [ClaudeWidgetSupervisorNative]::ProcessId($handle)-ne [int]$runtime.pid){$script:verifiedGui='';return $false}
    $identity=([string]$runtime.pid)+'|'+([string]$runtime.widget)+'|'+([string]$runtime.processStartedAt)+'|'+([string]$runtime.startedAt)
    if($identity-eq $script:verifiedGui){return $true}
    $script:verifiedGui=''
    $process=Get-Process -Id ([int]$runtime.pid) -ErrorAction Stop
    if($process.ProcessName-notin @('powershell','pwsh')){return $false}
    if($runtime.processStartedAt){
      if(([DateTime]$runtime.processStartedAt).ToUniversalTime()-ne $process.StartTime.ToUniversalTime()){return $false}
    }else{
      $recorded=([DateTime]$runtime.startedAt).ToUniversalTime()
      $gap=($recorded-$process.StartTime.ToUniversalTime()).TotalSeconds
      if($gap-lt 0 -or $gap-gt 120){return $false}
    }
    $command=(Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$runtime.pid) -ErrorAction Stop).CommandLine
    $scriptFile=Join-Path $ExpectedAppDir 'widget.ps1'
    $matched=$command.IndexOf(('"'+$scriptFile+'"'),[StringComparison]::OrdinalIgnoreCase)-ge 0
    if($matched){$script:verifiedGui=$identity}
    return $matched
  }catch{$script:verifiedGui='';return $false}finally{if($process){$process.Dispose()}}
}

if($CheckOnly){return [pscustomobject]@{ok=$true;info=$info;hosts=@([ClaudeHostWindow]::Hosts())}}

$mutex=[Threading.Mutex]::new($false,('Local\ClaudeNiangSupervisor-'+$info.Sid))
$owned=$false
try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
if(!$owned){$mutex.Dispose();exit 0}
$pauseFile=Join-Path $info.DataDir 'supervisor-pause.json'
$nextLaunch=[DateTime]::MinValue
$nextStatus=[DateTime]::MinValue
$lastStatus=''
$lastVisibleHostKey=''
$pendingGui=$null
$supervisorProcess=Get-Process -Id $PID
try{$processStartedAt=$supervisorProcess.StartTime.ToUniversalTime().ToString('o')}finally{$supervisorProcess.Dispose()}
Write-WidgetLog $info.DataDir 'supervisor' '监督进程启动'
try{
  while($true){
    if((Test-Path -LiteralPath (Join-Path $info.DataDir 'supervisor-disabled.flag')) -or (Test-Path -LiteralPath (Join-Path $info.DataDir 'supervisor-stop.flag'))){break}
    try{
      $hosts=@([ClaudeHostWindow]::Hosts())
      $settings=$null;try{$settings=Read-WidgetCachedJson (Join-Path $info.DataDir 'settings.json')}catch{}
      $desktop=$settings -and $null-ne $settings.followHost -and !$settings.followHost
      $pause=$null;try{$pause=Read-WidgetCachedJson $pauseFile}catch{}
      $paused=Test-WidgetSupervisorPause $pause $hosts
      if($pause -and !$paused){Remove-Item -LiteralPath $pauseFile -ErrorAction SilentlyContinue}
      $visible=@($hosts|Where-Object{$_.visible})
      $visibleHostKey=(@($visible|Sort-Object handle|ForEach-Object{'{0}:{1}:{2}'-f $_.handle,$_.pid,$_.started}) -join '|')
      if($visibleHostKey-ne $lastVisibleHostKey){$nextLaunch=[DateTime]::MinValue;$lastVisibleHostKey=$visibleHostKey}
      $running=Get-WidgetSupervisorRunningGui $info.DataDir $info.AppDir
      # Retain the launch handle until startup finishes, so slow WPF startup
      # cannot create another GUI process before runtime.json is available.
      if($pendingGui -and ($running -or $pendingGui.HasExited)){$pendingGui.Dispose();$pendingGui=$null}
      if(!$paused -and ($desktop -or $visible.Count-gt 0) -and !$running -and !$pendingGui -and [DateTime]::UtcNow-ge $nextLaunch){
        $nextLaunch=[DateTime]::UtcNow.AddSeconds(10)
        $powerShell=Get-WidgetPowerShellPath
        Write-WidgetLog $info.DataDir 'supervisor' '启动挂件界面'
        $pendingGui=Start-Process -FilePath $powerShell -ArgumentList @('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $info.AppDir 'runtime\start-widget.ps1')+'"'),'-WidgetPath',('"'+(Join-Path $info.AppDir 'widget.ps1')+'"')) -WindowStyle Hidden -PassThru
      }
      # supervisor-status.json is only for diagnosis: rewrite it when its
      # content changes, otherwise once a minute.
      $statusKey=@($hosts.Count,$visible.Count,$paused,$running)-join '|'
      if($statusKey-ne $lastStatus -or [DateTime]::UtcNow-ge $nextStatus){
        Write-WidgetSupervisorJson (Join-Path $info.DataDir 'supervisor-status.json') @{pid=$PID;processStartedAt=$processStartedAt;at=[DateTime]::UtcNow.ToString('o');mainWindows=$hosts.Count;visibleWindows=$visible.Count;paused=$paused;widgetRunning=$running;taskName=$info.TaskName}
        $lastStatus=$statusKey;$nextStatus=[DateTime]::UtcNow.AddSeconds(60)
      }
    }catch{Write-WidgetLog $info.DataDir 'supervisor' $_}
    Start-Sleep -Milliseconds 1500
  }
}finally{
  Write-WidgetLog $info.DataDir 'supervisor' '监督进程退出'
  if($pendingGui){$pendingGui.Dispose()}
  try{
    $statusFile=Join-Path $info.DataDir 'supervisor-status.json'
    $status=Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$status.pid-eq $PID){Remove-Item -LiteralPath $statusFile -ErrorAction SilentlyContinue}
  }catch{}
  try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()
}
