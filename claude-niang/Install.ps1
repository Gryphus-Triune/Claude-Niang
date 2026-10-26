param([switch]$CheckOnly,[switch]$NoLogin)
# Claude 娘安装：在当前文件夹登记挂件（不需要管理员权限）。
# 每次运行都会把过程写进同一文件夹的 install-log.txt，方便排查。
$ErrorActionPreference='Stop'
$appDir=$PSScriptRoot
$script:installLog=New-Object 'System.Collections.Generic.List[string]'
function Say([string]$Text,[string]$Color='Gray'){Write-Host $Text -ForegroundColor $Color;$script:installLog.Add($Text)}
function Note([string]$Text){$script:installLog.Add($Text)}
function Save-InstallLog {
  try{[IO.File]::WriteAllText((Join-Path $appDir 'install-log.txt'),($script:installLog-join "`r`n"),[Text.UTF8Encoding]::new($true))}catch{}
}
$exitCode=0
try{
  Note ('时间：'+[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'))
  try{
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    Note ('账户：'+$identity.Name+'  SID：'+$identity.User.Value+'  USERDOMAIN='+$env:USERDOMAIN+'  USERNAME='+$env:USERNAME)
    $identity.Dispose()
  }catch{Note ('账户信息读取失败：'+$_.Exception.Message)}
  Note ('系统：'+[Environment]::OSVersion.VersionString+'  PowerShell '+$PSVersionTable.PSVersion+'  .NET '+[Environment]::Version)
  # Files extracted from a ZIP downloaded from the internet carry a "from the
  # internet" mark, and .NET then refuses to load the bundled WebView2 DLLs.
  # Clear the mark on this package's own files only.
  $packageRoot=Split-Path $appDir -Parent
  $packaged=@(Get-ChildItem -LiteralPath $appDir -Recurse -File -ErrorAction SilentlyContinue)+@(Get-ChildItem -LiteralPath $packageRoot -Filter '*.cmd' -File -ErrorAction SilentlyContinue)+@(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'Claude桌面扩展') -File -ErrorAction SilentlyContinue)
  foreach($file in $packaged){try{Unblock-File -LiteralPath $file.FullName -ErrorAction Stop}catch{}}
  . (Join-Path $appDir 'runtime\common.ps1')
  . (Join-Path $appDir 'runtime\supervisor-task.ps1')
  . (Join-Path $appDir 'runtime\install-preflight.ps1')
  Say '== Claude 娘额度挂件 安装 ==' 'Yellow'
  $config=Get-WidgetInstallPreflight -SourceDir $appDir -AppDir $appDir
  Say ('程序位置：'+$config.appDir)
  Say ('数据位置：'+(Split-Path $config.dataDir -Parent))
  Say ('Node.js：'+$config.nodeVersion+'  '+$config.nodePath)
  $webview=Test-WidgetWebView2 $appDir
  if(!$webview.ok){
    if($webview.errorCode-eq 'NO_WEBVIEW2'){throw '缺少 Microsoft Edge WebView2 运行时。请从 https://developer.microsoft.com/microsoft-edge/webview2/ 下载「常青版独立安装程序」安装后，再运行本安装。'}
    throw ('内置浏览器组件检查失败：'+$webview.error)
  }
  Say ('WebView2：'+$webview.runtimeVersion)
  $claude=@(Find-WidgetClaudeDesktop)
  if($claude.Count){Say ('Claude 桌面端：已找到')}else{Say 'Claude 桌面端：暂未找到（装好或打开 Claude 后挂件会自动出现）' 'DarkYellow'}
  Note ('Claude 路径：'+($claude-join '; '))
  if($CheckOnly){[pscustomobject]@{ok=$true;appDir=$appDir;dataDir=$config.dataDir;node=$config.nodePath;webview=$webview.runtimeVersion;claude=$claude}|ConvertTo-Json;return}

  $null=New-Item -ItemType Directory -Path $config.dataDir -Force
  Stop-WidgetSupervisorTask -AppDir $appDir -Configuration ([pscustomobject]$config)
  Stop-WidgetGui -AppDir $appDir -DataDir $config.dataDir
  Write-WidgetSupervisorJson (Join-Path $appDir 'installation.json') $config
  $link=(New-Object -ComObject WScript.Shell).CreateShortcut($config.startupShortcut)
  # Startup is an independent fallback if the scheduled task cannot run.
  $link.TargetPath=Get-WidgetPowerShellPath
  $link.Arguments=Get-WidgetSupervisorArguments $appDir
  $link.WorkingDirectory=Join-Path $env:WINDIR 'System32'
  $link.WindowStyle=7
  $link.Description='Claude娘：Claude 桌面端额度挂件'
  $link.Save()
  Note ('启动文件夹快捷方式：'+$config.startupShortcut)
  $task=Register-WidgetSupervisorTask -AppDir $appDir
  foreach($line in @($task.TaskErrors)){Note ('计划任务尝试：'+$line)}
  if($task.TaskRegistered){
    Say ('已登记开机自动启动：'+$task.TaskName) 'Green'
    Note ('计划任务方式：'+$task.TaskMethod)
  }else{
    Say '计划任务登记没有成功，已改用「启动」文件夹开机自启（不影响使用）。' 'DarkYellow'
    Say ('原因：'+@($task.TaskErrors)[0]) 'DarkGray'
  }
  Say ''
  Say '安装完成！打开 Claude 桌面端主窗口，右下角就会出现 Claude 娘。' 'Green'
  Say '· 点角色看额度，点气泡翻页/看语录；右键角色打开设置。'
  Say '· 换成你自己的形象：右键角色 → 更换形象 → 添加形象。'
  $mcpb=Join-Path (Split-Path $appDir -Parent) 'Claude桌面扩展\claude-niang-usage.mcpb'
  if(Test-Path -LiteralPath $mcpb){Say ('· 可选：双击「'+$mcpb+'」装到 Claude 桌面端，就能直接问 Claude「我还剩多少额度」。')}
  Say ''
  Save-InstallLog
  if(!$NoLogin){
    $status=Read-WidgetJsonFile (Join-Path $config.dataDir 'status.json')
    $signedIn=$status -and $status.ok -and $status.errorCode-ne 'NOT_LOGGED_IN'
    if(!$signedIn){
      Say 'Claude 娘需要在她自己的小窗口里登录一次 claude.ai 才能读取额度。' 'Yellow'
      $answer=Read-Host '现在打开登录窗口吗？[Y/n]'
      if($answer-notmatch '^(n|no|否)$'){
        try{& (Join-Path $appDir 'Login.ps1')}
        catch{Say ('登录窗口没能打开：'+$_.Exception.Message+'（安装已经完成，可以稍后运行「登录Claude账号.cmd」）') 'DarkYellow';Note ('登录错误：'+$_.Exception.ToString())}
      }else{Say '以后可以运行「登录Claude账号.cmd」，或右键角色 → Claude 账号 → 登录。'}
    }
  }
}catch{
  Say ''
  Say ('安装没有完成：'+$_.Exception.Message) 'Red'
  Note ('详细错误：'+$_.Exception.ToString())
  Note ('位置：'+$_.InvocationInfo.PositionMessage)
  Say ('详细记录已保存到：'+(Join-Path $appDir 'install-log.txt')) 'DarkGray'
  $exitCode=1
}finally{
  Save-InstallLog
}
exit $exitCode
