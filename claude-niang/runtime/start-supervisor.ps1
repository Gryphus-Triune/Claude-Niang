$ErrorActionPreference='Stop'
$appDir=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')
. (Join-Path $PSScriptRoot 'log.ps1')
try{
  $info=Get-WidgetSupervisorInfo $appDir
  $launch=Resolve-WidgetSupervisorLaunch $appDir
  if($launch.Kind-eq 'headless'){Write-WidgetLog $info.DataDir 'supervisor' ('启动程序无法运行，改用 conhost 隐藏启动：'+$launch.Reason)}
  # Registrations from earlier versions start a visible PowerShell or depend on
  # VBScript, and policy may block the launcher later; opening Claude娘 moves
  # this folder's registrations to the launch form that works now.
  $shortcut=[string](Read-WidgetJsonFile (Join-Path $appDir 'installation.json')).startupShortcut
  if($shortcut -and (Test-Path -LiteralPath $shortcut)){
    $link=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    if((Test-WidgetStartupShortcutIdentity $link $info.AppDir) -and (Get-WidgetSupervisorCommandKind ([string]$link.TargetPath) ([string]$link.Arguments) $info.AppDir)-ne 'headless'){Set-WidgetStartupShortcut $shortcut $info.AppDir}
  }
  $installed=Get-WidgetSupervisorTask $info
  if($installed -and (Test-WidgetSupervisorTaskCurrent $installed $launch)){Start-WidgetSupervisorTask $appDir}else{Register-WidgetSupervisorTask $appDir|Out-Null}
}catch{
  $failure=$_
  try{$configuration=Get-Content -LiteralPath (Join-Path $appDir 'installation.json') -Raw -Encoding UTF8|ConvertFrom-Json;Write-WidgetLog $configuration.dataDir 'supervisor' ('计划任务没能启动监督进程，改为直接运行：'+$failure.Exception.Message)}catch{}
  # Last resort: run the supervisor directly, as the Startup shortcut does.
  try{$fallback=Get-WidgetSupervisorInfo $appDir;Resume-WidgetSupervisor $appDir;Start-WidgetSupervisorProcess $fallback}catch{throw $failure}
}
