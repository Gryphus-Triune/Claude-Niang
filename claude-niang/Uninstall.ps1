# 停用 Claude 娘：移除开机启动并关闭挂件。程序文件、设置、语录和登录状态都会保留。
$ErrorActionPreference='Stop'
try{
  $configPath=Join-Path $PSScriptRoot 'installation.json'
  if(!(Test-Path -LiteralPath $configPath)){Write-Host '这个文件夹还没有安装过 Claude 娘。' -ForegroundColor Yellow;exit 0}
  $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
  . (Join-Path $PSScriptRoot 'runtime\common.ps1')
  . (Join-Path $PSScriptRoot 'runtime\supervisor-task.ps1')
  $null=Get-WidgetSupervisorInfo -AppDir $PSScriptRoot -Configuration $config
  # Refuse a foreign startup registration before stopping this installation.
  if(Test-Path -LiteralPath $config.startupShortcut){
    $link=(New-Object -ComObject WScript.Shell).CreateShortcut($config.startupShortcut)
    if(!(Test-WidgetStartupShortcutIdentity -Shortcut $link -AppDir $PSScriptRoot)){throw '启动文件夹里的 Claude 娘快捷方式属于另一个安装位置，未做修改。'}
  }
  $null=Unregister-WidgetSupervisorTask -AppDir $PSScriptRoot
  Stop-WidgetGui -AppDir $PSScriptRoot -DataDir $config.dataDir
  if(Test-Path -LiteralPath $config.startupShortcut){Remove-Item -LiteralPath $config.startupShortcut}
  $config|Add-Member -NotePropertyName disabledAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
  Write-WidgetSupervisorJson $configPath $config
  Write-Host '已停用 Claude 娘：开机启动已移除，挂件已关闭。' -ForegroundColor Green
  Write-Host '程序文件、设置和登录状态都还在。要彻底删除：删掉整个程序文件夹，再删掉 %LOCALAPPDATA%\ClaudeNiang。'
}catch{
  Write-Host ('停用没有完成：'+$_.Exception.Message) -ForegroundColor Red
  exit 1
}
