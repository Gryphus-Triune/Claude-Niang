function Get-WidgetInstallationDataDir {
  param([Parameter(Mandatory=$true)][string]$AppDir,[Parameter(Mandatory=$true)]$Configuration)
  if(![string]$Configuration.appDir -or ![string]$Configuration.dataDir){throw 'Installation paths are missing.'}
  $root=[IO.Path]::GetFullPath($AppDir).TrimEnd('\')
  $previousRoot=[IO.Path]::GetFullPath([string]$Configuration.appDir).TrimEnd('\')
  $data=[IO.Path]::GetFullPath([string]$Configuration.dataDir)
  if($previousRoot-ine $root){
    # A moved installation may retain its preferences, but a copied active one may not claim the same registration.
    if(Test-Path -LiteralPath $previousRoot){throw '原来的安装文件夹还在。请先在原文件夹运行「停用Claude娘.cmd」，再移动或重新安装。'}
    $disabled=[bool]$Configuration.disabledAt -or (Test-Path -LiteralPath (Join-Path $data 'supervisor-disabled.flag'))
    if(!$disabled){throw '安装文件夹被移动过但没有先停用。'}
  }
  return $data
}

function Get-WidgetPowerShellPath {return (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')}

# Task Scheduler and the Startup folder run the supervisor directly. A second
# copy exits immediately because the supervisor holds a per-user mutex.
function Get-WidgetSupervisorArguments([string]$AppDir){
  return ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path ([IO.Path]::GetFullPath($AppDir).TrimEnd('\')) 'runtime\supervisor.ps1')+'"')
}

# Task Scheduler and the Startup folder start the supervisor through a small
# windowless launcher (runtime\launcher.cs) compiled at install time. A
# PowerShell started directly with a normal window is handed to Windows Terminal
# on Windows 11, where -WindowStyle Hidden cannot hide it, and closing that empty
# window ended the supervisor.
function Get-WidgetLauncherPath([string]$AppDir){
  return (Join-Path ([IO.Path]::GetFullPath($AppDir).TrimEnd('\')) 'runtime\claude-niang-launcher.exe')
}

# Builds the launcher, or rebuilds it when runtime\launcher.cs has changed (the
# source hash is stored as the program's product version). A running copy (the
# scheduled task waits on it) cannot be overwritten, but it can be renamed.
function Initialize-WidgetLauncher([string]$AppDir){
  $root=[IO.Path]::GetFullPath($AppDir).TrimEnd('\')
  $source=Join-Path $root 'runtime\launcher.cs';$target=Get-WidgetLauncherPath $root
  # Copies renamed while still running are removed once they have exited.
  foreach($old in @(Get-ChildItem -LiteralPath (Split-Path $target -Parent) -Filter 'claude-niang-launcher.exe.*.old' -ErrorAction SilentlyContinue)){try{Remove-Item -LiteralPath $old.FullName -ErrorAction Stop}catch{}}
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$hash=([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($source)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
  if([IO.File]::Exists($target) -and [Diagnostics.FileVersionInfo]::GetVersionInfo($target).ProductVersion-eq $hash){return $target}
  $temp=$target+'.'+[Guid]::NewGuid().ToString('N')+'.build.exe'
  try{
    $code=[IO.File]::ReadAllText($source,[Text.Encoding]::UTF8)-replace '(?m)^static class ',('[assembly: System.Reflection.AssemblyInformationalVersion("'+$hash+'")]'+"`r`nstatic class ")
    Add-Type -TypeDefinition $code -OutputAssembly $temp -OutputType WindowsApplication -ErrorAction Stop
    if([IO.File]::Exists($target)){[IO.File]::Move($target,$target+'.'+[Guid]::NewGuid().ToString('N')+'.old')}
    [IO.File]::Move($temp,$target)
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
  return $target
}

function Get-WidgetHeadlessArguments([string]$AppDir){
  return ('--headless "'+(Get-WidgetPowerShellPath)+'" '+(Get-WidgetSupervisorArguments $AppDir))
}

# How Task Scheduler and the Startup folder start the supervisor: the launcher
# where it may run, otherwise conhost.exe --headless. Smart App Control, AppLocker
# and similar policies can block a locally built, unsigned program; conhost.exe
# ships with Windows and also keeps the console invisible (it does not pass on
# the supervisor's exit code, so restart-after-failure does not apply there).
# The launcher is tried once per process.
function Resolve-WidgetSupervisorLaunch([string]$AppDir){
  $root=[IO.Path]::GetFullPath($AppDir).TrimEnd('\')
  if($script:widgetSupervisorLaunch -and $script:widgetSupervisorLaunch.AppDir-ieq $root){return $script:widgetSupervisorLaunch}
  $launch=$null;$reason=$null
  try{
    $launcher=Initialize-WidgetLauncher $root
    $check=Start-Process -FilePath $launcher -ArgumentList 'check' -WindowStyle Hidden -PassThru -ErrorAction Stop
    try{
      if(!$check.WaitForExit(10000)){$reason='launcher check timed out'}
      elseif($check.ExitCode-ne 0){$reason='launcher check exited '+$check.ExitCode}
      else{$launch=[pscustomobject]@{AppDir=$root;Kind='launcher';Execute=$launcher;Arguments='supervisor';Reason=$null}}
    }finally{$check.Dispose()}
  }catch{$reason=$_.Exception.Message}
  if(!$launch){$launch=[pscustomobject]@{AppDir=$root;Kind='headless';Execute=(Join-Path $env:WINDIR 'System32\conhost.exe');Arguments=(Get-WidgetHeadlessArguments $root);Reason=$reason}}
  $script:widgetSupervisorLaunch=$launch
  return $launch
}

# 'launcher' or 'headless' for the two current forms, 'legacy' for what earlier
# versions registered for this same folder (a direct PowerShell command, or
# runtime\supervisor.vbs under wscript.exe), $null for anything else.
function Get-WidgetSupervisorCommandKind([string]$Execute,[string]$Arguments,[string]$AppDir){
  if(!$Execute){return $null}
  try{$file=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Execute))}catch{return $null}
  $root=[IO.Path]::GetFullPath($AppDir).TrimEnd('\');$Arguments=[string]$Arguments
  if($file-ieq (Get-WidgetLauncherPath $root) -and $Arguments.Trim()-ieq 'supervisor'){return 'launcher'}
  if($file-ieq (Join-Path $env:WINDIR 'System32\conhost.exe') -and $Arguments-ieq (Get-WidgetHeadlessArguments $root)){return 'headless'}
  if($file-ieq (Get-WidgetPowerShellPath) -and $Arguments-ieq (Get-WidgetSupervisorArguments $root)){return 'legacy'}
  if($file-ieq (Join-Path $env:WINDIR 'System32\wscript.exe') -and $Arguments-ieq ('//B //NoLogo "'+(Join-Path $root 'runtime\supervisor.vbs')+'"')){return 'legacy'}
  return $null
}

function Test-WidgetStartupShortcutIdentity {
  param([Parameter(Mandatory=$true)]$Shortcut,[Parameter(Mandatory=$true)][string]$AppDir)
  return [bool](Get-WidgetSupervisorCommandKind ([string]$Shortcut.TargetPath) ([string]$Shortcut.Arguments) $AppDir)
}

# The Startup shortcut is an independent fallback if the scheduled task cannot
# run, so it always uses conhost.exe --headless: should policy start blocking the
# launcher after installation, the shortcut still starts the supervisor at sign-in
# (the task's copy and this one share a mutex, so only one keeps running).
function Set-WidgetStartupShortcut([string]$Path,[string]$AppDir){
  $link=(New-Object -ComObject WScript.Shell).CreateShortcut($Path)
  $link.TargetPath=Join-Path $env:WINDIR 'System32\conhost.exe'
  $link.Arguments=Get-WidgetHeadlessArguments $AppDir
  $link.WorkingDirectory=Join-Path $env:WINDIR 'System32'
  $link.WindowStyle=7
  $link.Description='Claude娘：Claude 桌面端额度挂件'
  $link.Save()
}

function Stop-WidgetGui {
  param([Parameter(Mandatory=$true)][string]$AppDir,[Parameter(Mandatory=$true)][string]$DataDir)
  $null=New-Item -ItemType Directory -Path $DataDir -Force
  $stopFile=Join-Path $DataDir 'stop.flag'
  $runtime=$null
  try{$runtime=Get-Content -LiteralPath (Join-Path $DataDir 'runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
  $guiPid=0
  if(!$runtime -or ![int]::TryParse([string]$runtime.pid,[ref]$guiPid) -or $guiPid-le 0){
    # runtime.json is written late in startup. A GUI that is still between
    # start-widget.ps1 and that write would otherwise keep running after the
    # stop request (and delete stop.flag itself), leaving an unsupervised pet.
    $expectedStart='"'+(Join-Path $AppDir 'runtime\start-widget.ps1')+'"'
    $expectedWidget='"'+(Join-Path $AppDir 'widget.ps1')+'"'
    $launching=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop|Where-Object{
      $_.ProcessId-ne $PID -and [string]$_.CommandLine -and ($_.CommandLine.IndexOf($expectedStart,[StringComparison]::OrdinalIgnoreCase)-ge 0 -or $_.CommandLine.IndexOf($expectedWidget,[StringComparison]::OrdinalIgnoreCase)-ge 0)
    })
    if(!$launching.Count){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
    [IO.File]::WriteAllText($stopFile,'stop')
    $deadline=[DateTime]::UtcNow.AddSeconds(6)
    do{
      $alive=@($launching|Where-Object{
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$_.ProcessId) -ErrorAction SilentlyContinue
        $current -and $current.CreationDate-eq $_.CreationDate
      })
      if(!$alive.Count){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
      Start-Sleep -Milliseconds 100
    }while([DateTime]::UtcNow-lt $deadline)
    throw '正在启动的挂件 6 秒内没有退出。'
  }
  $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$guiPid) -ErrorAction Stop
  $expectedGui='"'+(Join-Path $AppDir 'widget.ps1')+'"'
  if(!$process -or $process.Name-notin @('powershell.exe','pwsh.exe') -or ![string]$process.CommandLine -or $process.CommandLine.IndexOf($expectedGui,[StringComparison]::OrdinalIgnoreCase)-lt 0){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
  [IO.File]::WriteAllText($stopFile,'stop')
  $deadline=[DateTime]::UtcNow.AddSeconds(6)
  do{
    $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$guiPid) -ErrorAction Stop
    # Do not wait for an unrelated process that reused the previous GUI's PID.
    if(!$current -or $current.CreationDate-ne $process.CreationDate){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
    Start-Sleep -Milliseconds 100
  }while([DateTime]::UtcNow-lt $deadline)
  throw '之前的挂件 6 秒内没有退出。'
}

function Get-WidgetSupervisorInfo {
  param([Parameter(Mandatory=$true)][string]$AppDir,$Configuration=$null)
  $root=[IO.Path]::GetFullPath($AppDir).TrimEnd('\')
  $config=$Configuration
  if(!$config){$config=Get-Content -LiteralPath (Join-Path $root 'installation.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json}
  if(![string]$config.appDir -or ![string]$config.dataDir){throw 'Installation paths are missing.'}
  if([IO.Path]::GetFullPath([string]$config.appDir).TrimEnd('\')-ine $root){throw 'Supervisor installation identity mismatch.'}
  $data=[IO.Path]::GetFullPath([string]$config.dataDir)
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  [pscustomobject]@{AppDir=$root;DataDir=$data;Sid=$sid;TaskName=('Claude Niang - '+$sid);TaskPath='\';Execute=(Get-WidgetLauncherPath $root);Arguments='supervisor';WorkingDirectory=(Join-Path $env:WINDIR 'System32')}
}

function Resolve-WidgetSupervisorSid([string]$Identity){
  if($Identity-match '^S-\d-') {return ([Security.Principal.SecurityIdentifier]::new($Identity)).Value}
  return ([Security.Principal.NTAccount]::new($Identity)).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Assert-WidgetSupervisorTaskIdentity {
  param([Parameter(Mandatory=$true)]$Task,[Parameter(Mandatory=$true)]$Info)
  if($Task.TaskName-ine $Info.TaskName -or $Task.TaskPath-ine $Info.TaskPath){throw 'Supervisor task name mismatch.'}
  # Task Scheduler may report the owner as a SID or as an account name, and on
  # some accounts the name cannot be translated back; any known spelling counts.
  $owner=[string]$Task.Principal.UserId
  $ownerSid=$null;try{if($owner){$ownerSid=Resolve-WidgetSupervisorSid $owner}}catch{}
  if($ownerSid){if($ownerSid-ne $Info.Sid){throw 'Supervisor task owner mismatch.'}}
  elseif($owner -and !@(Get-WidgetCurrentAccountNames|Where-Object{$_-ieq $owner}).Count){throw 'Supervisor task owner mismatch.'}
  if([string]$Task.Principal.LogonType-notin @('Interactive','3') -or [string]$Task.Principal.RunLevel-notin @('Limited','0')){throw 'Supervisor task privilege mismatch.'}
  $actions=@($Task.Actions)
  if($actions.Count-ne 1){throw 'Supervisor task action count mismatch.'}
  $action=$actions[0]
  # A task registered by another Claude娘 folder points at that folder's
  # supervisor; it is not ours to replace silently. This folder's older direct
  # PowerShell command is ours and is upgraded by Register-WidgetSupervisorTask.
  if(!(Get-WidgetSupervisorCommandKind ([string]$action.Execute) ([string]$action.Arguments) $Info.AppDir)){throw '已有另一个位置的 Claude 娘登记了自动启动。请先在原文件夹运行「停用Claude娘.cmd」。'}
}

# Whether a task or shortcut already uses the chosen launch form. Anything else
# of ours (an earlier form, or the launcher after policy started blocking it) is
# replaced by Register-WidgetSupervisorTask or Set-WidgetStartupShortcut.
function Test-WidgetSupervisorCommandCurrent([string]$Execute,[string]$Arguments,$Launch){
  return (Get-WidgetSupervisorCommandKind $Execute $Arguments $Launch.AppDir)-eq $Launch.Kind
}
function Test-WidgetSupervisorTaskCurrent($Task,$Launch){
  $action=@($Task.Actions)[0]
  return Test-WidgetSupervisorCommandCurrent ([string]$action.Execute) ([string]$action.Arguments) $Launch
}

function Get-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)]$Info)
  if(!(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)){return $null}
  $service=Get-Service -Name Schedule -ErrorAction SilentlyContinue
  if($service -and $service.Status-ne 'Running'){return $null}
  $tasks=@(Get-ScheduledTask -TaskPath $Info.TaskPath -ErrorAction Stop|Where-Object{$_.TaskName-eq $Info.TaskName})
  if($tasks.Count-gt 1){throw 'Multiple supervisor tasks found.'}
  if($tasks.Count-eq 1){Assert-WidgetSupervisorTaskIdentity $tasks[0] $Info;return $tasks[0]}
  return $null
}

function Write-WidgetSupervisorJson([string]$File,$Value){
  $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($File)) -Force
  Write-WidgetFileAtomic $File ($Value|ConvertTo-Json -Depth 6)
}

function Set-WidgetSupervisorPause {
  param([Parameter(Mandatory=$true)][string]$AppDir,[long]$HostHandle=0,[int]$HostPid=0)
  $info=Get-WidgetSupervisorInfo $AppDir
  if($HostHandle-le 0){try{$presence=Get-Content -LiteralPath (Join-Path $info.DataDir 'presence.json') -Raw -Encoding UTF8|ConvertFrom-Json;$HostHandle=[long]$presence.host}catch{}}
  if($HostHandle-gt 0 -and $HostPid-le 0){
    if(!('ClaudeWidgetSupervisorPauseNative' -as [type])){Add-WidgetType -TypeName ClaudeWidgetSupervisorPauseNative -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ClaudeWidgetSupervisorPauseNative {
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 public static int ProcessId(IntPtr h){uint pid;GetWindowThreadProcessId(h,out pid);return (int)pid;}
}
'@}
    $HostPid=[ClaudeWidgetSupervisorPauseNative]::ProcessId([IntPtr]$HostHandle)
  }
  $started=0L
  if($HostPid-gt 0){try{$started=(Get-Process -Id $HostPid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks}catch{}}
  Write-WidgetSupervisorJson (Join-Path $info.DataDir 'supervisor-pause.json') @{host=$HostHandle;hostPid=$HostPid;hostStarted=$started;at=[DateTime]::UtcNow.ToString('o')}
}

function Resume-WidgetSupervisor {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  foreach($name in @('supervisor-pause.json','supervisor-disabled.flag','supervisor-stop.flag')){
    $file=Join-Path $info.DataDir $name
    if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -ErrorAction Stop}
  }
}

function Disable-WidgetSupervisor {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $null=New-Item -ItemType Directory -Path $info.DataDir -Force
  [IO.File]::WriteAllText((Join-Path $info.DataDir 'supervisor-disabled.flag'),'disabled')
}

# Every spelling of the current account that Task Scheduler might accept.
function Get-WidgetCurrentAccountNames {
  $names=New-Object 'System.Collections.Generic.List[string]'
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  try{
    $names.Add($identity.User.Value)
    if($identity.Name){$names.Add($identity.Name)}
    try{$translated=$identity.User.Translate([Security.Principal.NTAccount]).Value;if($translated){$names.Add($translated)}}catch{}
  }finally{$identity.Dispose()}
  if($env:USERDOMAIN -and $env:USERNAME){$names.Add($env:USERDOMAIN+'\'+$env:USERNAME)}
  if($env:USERNAME){$names.Add($env:USERNAME)}
  $seen=@{};foreach($name in $names){if($name -and !$seen.ContainsKey($name.ToLowerInvariant())){$seen[$name.ToLowerInvariant()]=$true;$name}}
}

$script:WidgetTaskDescription='Claude娘：在 Claude 桌面端主窗口右下角显示额度挂件（当前用户，无管理员权限）。'

# The same task written as Task Scheduler XML, so the account text is exactly
# what we choose (some accounts fail when the ScheduledTasks objects convert it).
function New-WidgetSupervisorTaskXml {
  param([Parameter(Mandatory=$true)]$Info,[Parameter(Mandatory=$true)][string]$Account,[string]$TriggerUser)
  $x={param($value)[Security.SecurityElement]::Escape([string]$value)}
  $lines=@(
    '<?xml version="1.0" encoding="UTF-16"?>',
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">',
    '  <RegistrationInfo>',
    ('    <Description>'+(& $x $script:WidgetTaskDescription)+'</Description>'),
    '  </RegistrationInfo>',
    '  <Triggers>',
    '    <LogonTrigger>',
    '      <Enabled>true</Enabled>'
  )
  if($TriggerUser){$lines+=('      <UserId>'+(& $x $TriggerUser)+'</UserId>')}
  $lines+=@(
    '    </LogonTrigger>',
    '  </Triggers>',
    '  <Principals>',
    '    <Principal id="Author">',
    ('      <UserId>'+(& $x $Account)+'</UserId>'),
    '      <LogonType>InteractiveToken</LogonType>',
    '      <RunLevel>LeastPrivilege</RunLevel>',
    '    </Principal>',
    '  </Principals>',
    '  <Settings>',
    '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>',
    '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
    '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>',
    '    <AllowHardTerminate>true</AllowHardTerminate>',
    '    <StartWhenAvailable>true</StartWhenAvailable>',
    '    <AllowStartOnDemand>true</AllowStartOnDemand>',
    '    <Enabled>true</Enabled>',
    '    <Hidden>true</Hidden>',
    '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>',
    '    <Priority>7</Priority>',
    '    <RestartOnFailure>',
    '      <Interval>PT1M</Interval>',
    '      <Count>3</Count>',
    '    </RestartOnFailure>',
    '  </Settings>',
    '  <Actions Context="Author">',
    '    <Exec>',
    ('      <Command>'+(& $x $Info.Execute)+'</Command>'),
    ('      <Arguments>'+(& $x $Info.Arguments)+'</Arguments>'),
    ('      <WorkingDirectory>'+(& $x $Info.WorkingDirectory)+'</WorkingDirectory>'),
    '    </Exec>',
    '  </Actions>',
    '</Task>'
  )
  return ($lines-join "`r`n")
}

# Try the usual registration first, then the XML form with each account
# spelling, then a logon trigger for any user. Returns which one worked.
function Register-WidgetSupervisorTaskDefinition {
  param([Parameter(Mandatory=$true)]$Info)
  $errors=New-Object 'System.Collections.Generic.List[string]'
  try{
    $definition=New-WidgetSupervisorTaskDefinition $Info
    Register-ScheduledTask -TaskName $Info.TaskName -TaskPath $Info.TaskPath -InputObject $definition -Force -ErrorAction Stop|Out-Null
    return [pscustomobject]@{ok=$true;method='objects';account=$Info.Sid;errors=@($errors)}
  }catch{$errors.Add('ScheduledTask 对象（SID）：'+(($_.Exception.Message-replace '\s+',' ').Trim()))}
  $accounts=@(Get-WidgetCurrentAccountNames)
  foreach($anyUser in @($false,$true)){
    foreach($account in $accounts){
      $triggerUser=if($anyUser){$null}else{$account}
      try{
        $xml=New-WidgetSupervisorTaskXml -Info $Info -Account $account -TriggerUser $triggerUser
        Register-ScheduledTask -Xml $xml -TaskName $Info.TaskName -TaskPath $Info.TaskPath -Force -ErrorAction Stop|Out-Null
        return [pscustomobject]@{ok=$true;method=$(if($anyUser){'xml-any-user'}else{'xml'});account=$account;errors=@($errors)}
      }catch{$errors.Add('XML（'+$account+$(if($anyUser){'，任意用户登录'}else{''})+'）：'+(($_.Exception.Message-replace '\s+',' ').Trim()))}
    }
  }
  return [pscustomobject]@{ok=$false;method=$null;account=$null;errors=@($errors)}
}

# The Startup-folder shortcut runs the same command; this starts it right now.
function Start-WidgetSupervisorProcess {
  param([Parameter(Mandatory=$true)]$Info)
  Start-Process -FilePath (Get-WidgetPowerShellPath) -ArgumentList (Get-WidgetSupervisorArguments $Info.AppDir) -WorkingDirectory (Join-Path $env:WINDIR 'System32') -WindowStyle Hidden
}

function New-WidgetSupervisorTaskDefinition {
  param([Parameter(Mandatory=$true)]$Info)
  $action=New-ScheduledTaskAction -Execute $Info.Execute -Argument $Info.Arguments -WorkingDirectory $Info.WorkingDirectory
  $principal=New-ScheduledTaskPrincipal -UserId $Info.Sid -LogonType Interactive -RunLevel Limited
  $trigger=New-ScheduledTaskTrigger -AtLogOn -User $Info.Sid
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
  New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description $script:WidgetTaskDescription
}

function Register-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $launch=Resolve-WidgetSupervisorLaunch $info.AppDir
  $info.Execute=$launch.Execute;$info.Arguments=$launch.Arguments
  foreach($relative in @('runtime\supervisor.ps1','widget.ps1')){if(!(Test-Path -LiteralPath (Join-Path $info.AppDir $relative))){throw "Missing supervisor file: $relative"}}
  $existing=Get-WidgetSupervisorTask $info
  if($existing -and [string]$existing.State-eq 'Running'){Stop-WidgetSupervisorTask $AppDir}
  Resume-WidgetSupervisor $AppDir
  $registration=[pscustomobject]@{ok=$true;method='existing';account=$null;errors=@()}
  # A missing task, or one in the older visible-console form, is (re)registered.
  if(!$existing -or !(Test-WidgetSupervisorTaskCurrent $existing $launch)){$registration=Register-WidgetSupervisorTaskDefinition $info}
  $registered=$null
  if($registration.ok){try{$registered=Get-WidgetSupervisorTask $info}catch{$registration.errors=@($registration.errors)+('登记后核对失败：'+$_.Exception.Message)}}
  if(!$registered){
    # Without the scheduled task the Startup-folder shortcut still starts the
    # widget at every sign-in; start the same supervisor now.
    $text=@('Claude 娘没能登记计划任务，已改用「启动」文件夹开机自启。',('时间：'+[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')))+@($registration.errors)
    try{[IO.File]::WriteAllText((Join-Path $info.DataDir 'task-error.txt'),($text-join "`r`n"),[Text.UTF8Encoding]::new($true))}catch{}
    Start-WidgetSupervisorProcess $info
    $info|Add-Member -NotePropertyName TaskRegistered -NotePropertyValue $false -Force
    $info|Add-Member -NotePropertyName TaskErrors -NotePropertyValue @($registration.errors) -Force
    return $info
  }
  Remove-Item -LiteralPath (Join-Path $info.DataDir 'task-error.txt') -ErrorAction SilentlyContinue
  # IgnoreNew handles a running instance; the CIM state can lag a stop.
  try{Start-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop}catch{Start-WidgetSupervisorProcess $info}
  $info|Add-Member -NotePropertyName TaskRegistered -NotePropertyValue $true -Force
  $info|Add-Member -NotePropertyName TaskMethod -NotePropertyValue $registration.method -Force
  $info|Add-Member -NotePropertyName TaskErrors -NotePropertyValue @($registration.errors) -Force
  return $info
}

function Start-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $task=Get-WidgetSupervisorTask $info
  if(!$task){throw 'Supervisor task is not installed.'}
  Resume-WidgetSupervisor $AppDir
  try{Start-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop}catch{Start-WidgetSupervisorProcess $info}
}

function Stop-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir,$Configuration=$null)
  $info=Get-WidgetSupervisorInfo $AppDir $Configuration
  $task=Get-WidgetSupervisorTask $info
  # Task state alone does not prove its child PowerShell has exited.
  $expectedScript='"'+(Join-Path $info.AppDir 'runtime\supervisor.ps1')+'"'
  $processes=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop|Where-Object{
    $_.ProcessId-ne $PID -and [string]$_.CommandLine -and $_.CommandLine.IndexOf($expectedScript,[StringComparison]::OrdinalIgnoreCase)-ge 0
  })
  $null=New-Item -ItemType Directory -Path $info.DataDir -Force
  [IO.File]::WriteAllText((Join-Path $info.DataDir 'supervisor-stop.flag'),'stop')
  if($task -and [string]$task.State-eq 'Running'){
    Stop-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop
  }
  $deadline=[DateTime]::UtcNow.AddSeconds(6)
  do{
    $running=$false
    if($task){
      $stopped=Get-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop
      $running=[string]$stopped.State-eq 'Running'
    }
    foreach($process in $processes){
      $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$process.ProcessId) -ErrorAction Stop
      if($current -and $current.CreationDate-eq $process.CreationDate){$running=$true}
    }
    if(!$running){return}
    Start-Sleep -Milliseconds 150
  }while([DateTime]::UtcNow-lt $deadline)
  throw '监督进程 6 秒内没有停止。'
}

function Unregister-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $task=Get-WidgetSupervisorTask $info
  Disable-WidgetSupervisor $AppDir
  Stop-WidgetSupervisorTask $AppDir
  if($task){Unregister-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -Confirm:$false -ErrorAction Stop}
}
