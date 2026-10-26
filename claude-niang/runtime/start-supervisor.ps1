$ErrorActionPreference='Stop'
$appDir=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')
try{
  $info=Get-WidgetSupervisorInfo $appDir
  $installed=Get-WidgetSupervisorTask $info
  if($installed){Start-WidgetSupervisorTask $appDir}else{Register-WidgetSupervisorTask $appDir|Out-Null}
  Remove-Item -LiteralPath (Join-Path $info.DataDir 'supervisor-start-error.txt') -ErrorAction SilentlyContinue
}catch{
  $failure=$_
  try{$configuration=Get-Content -LiteralPath (Join-Path $appDir 'installation.json') -Raw -Encoding UTF8|ConvertFrom-Json;[IO.File]::WriteAllText((Join-Path $configuration.dataDir 'supervisor-start-error.txt'),$failure.Exception.ToString())}catch{}
  # Last resort: run the supervisor directly, as the Startup shortcut does.
  try{$fallback=Get-WidgetSupervisorInfo $appDir;Resume-WidgetSupervisor $appDir;Start-WidgetSupervisorProcess $fallback}catch{throw $failure}
}
