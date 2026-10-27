function Test-WidgetWritableDirectory([string]$Directory) {
  $existing=$Directory
  while(!(Test-Path -LiteralPath $existing)){$existing=Split-Path $existing -Parent;if(!$existing){throw '找不到可写入的上级文件夹。'}}
  $probe=Join-Path $existing ('.claude-niang-write-'+[Guid]::NewGuid().ToString('N'))
  try{$stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Dispose()}
  catch{throw ('这个文件夹不能写入：'+$existing)}
  finally{if([IO.File]::Exists($probe)){[IO.File]::Delete($probe)}}
}
function Assert-WidgetNoReparsePoint([string]$Directory) {
  for($current=[IO.Path]::GetFullPath($Directory);$current;$current=Split-Path $current -Parent){
    if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes-band [IO.FileAttributes]::ReparsePoint)){throw ('安装路径里不能有链接文件夹：'+$current)}
  }
}

# Node.js 20+ runs the quota reader: node.exe on PATH, or a usual install location.
function Find-WidgetNode {
  $candidates=[Collections.Generic.List[string]]::new()
  foreach($command in @(Get-Command node.exe -All -ErrorAction SilentlyContinue)){if($command.Source){$candidates.Add($command.Source)}}
  foreach($root in @($env:ProgramFiles,${env:ProgramFiles(x86)},(Join-Path $env:LOCALAPPDATA 'Programs'))){if($root){$candidates.Add((Join-Path $root 'nodejs\node.exe'))}}
  if($env:NVM_SYMLINK){$candidates.Add((Join-Path $env:NVM_SYMLINK 'node.exe'))}
  # Volta and Scoop keep a stable node.exe shim even when PATH is not refreshed yet.
  if($env:LOCALAPPDATA){$candidates.Add((Join-Path $env:LOCALAPPDATA 'Volta\bin\node.exe'))}
  if($env:USERPROFILE){$candidates.Add((Join-Path $env:USERPROFILE 'scoop\shims\node.exe'))}
  foreach($path in $candidates){
    if(!$path -or !(Test-Path -LiteralPath $path -PathType Leaf)){continue}
    try{
      $version=(& $path --version 2>$null|Select-Object -First 1)
      if($version-match '^v(\d+)\.' -and [int]$Matches[1]-ge 20){return [pscustomobject]@{path=[IO.Path]::GetFullPath($path);version=$version}}
    }catch{}
  }
  return $null
}

# The widget's own small browser needs the Microsoft Edge WebView2 runtime
# (built into Windows 11 and installed with Edge on Windows 10).
function Test-WidgetWebView2([string]$AppDir,[string]$ConfigPath='') {
  $out=Join-Path ([IO.Path]::GetTempPath()) ('claude-niang-check-'+[Guid]::NewGuid().ToString('N')+'.json')
  try{
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $AppDir 'runtime\claude-browser.ps1'),'-Mode','check','-OutFile',$out)
    & (Get-WidgetPowerShellPath) @arguments|Out-Null
    $result=Get-Content -LiteralPath $out -Raw -Encoding UTF8|ConvertFrom-Json
    return $result
  }catch{return [pscustomobject]@{ok=$false;errorCode='NO_SDK';error=$_.Exception.Message}}
  finally{Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue}
}

function Find-WidgetClaudeDesktop {
  $paths=@()
  $squirrel=Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
  if(Test-Path -LiteralPath $squirrel){$paths+=$squirrel}
  try{foreach($package in @(Get-AppxPackage -Name '*Claude*' -ErrorAction Stop)){if($package.InstallLocation){$paths+=$package.InstallLocation}}}catch{}
  try{foreach($process in @(Get-Process -Name claude -ErrorAction SilentlyContinue)){try{if($process.Path){$paths+=$process.Path}}catch{}}}catch{}
  return @($paths|Select-Object -Unique)
}

function Get-WidgetInstallPreflight {
  param([Parameter(Mandatory=$true)][string]$SourceDir,[Parameter(Mandatory=$true)][string]$AppDir)
  $appDir=[IO.Path]::GetFullPath($AppDir).TrimEnd('\');$sourceDir=[IO.Path]::GetFullPath($SourceDir).TrimEnd('\')
  $localData=Get-WidgetLocalApplicationData
  if(!$localData){throw '找不到本机的 AppData\Local 文件夹。'}
  $dataRoot=Join-Path $localData 'ClaudeNiang'
  $dataDir=Join-Path $dataRoot 'state'
  $previousConfig=Join-Path $appDir 'installation.json'
  if(Test-Path -LiteralPath $previousConfig){$previous=Read-WidgetJsonFile $previousConfig;$dataDir=Get-WidgetInstallationDataDir -AppDir $appDir -Configuration $previous}
  $dataDir=[IO.Path]::GetFullPath($dataDir).TrimEnd('\')
  $webviewDir=Join-Path (Split-Path $dataDir -Parent) 'webview'
  if($appDir-ieq $dataDir -or $appDir.StartsWith($dataDir+'\',[StringComparison]::OrdinalIgnoreCase) -or $dataDir.StartsWith($appDir+'\',[StringComparison]::OrdinalIgnoreCase)){throw '数据文件夹不能和程序文件夹重叠，请把程序解压到别处。'}
  $node=Find-WidgetNode
  if(!$node){throw '需要 Node.js 20 或更新版本。请先从 https://nodejs.org 安装 LTS 版，再重新运行安装。'}
  $required=Read-WidgetJsonFile (Join-Path $sourceDir 'runtime\install-files.json')
  if(!$required){throw '缺少安装文件清单，请重新完整解压。'}
  foreach($file in $required){if(!(Test-Path -LiteralPath (Join-Path $sourceDir $file) -PathType Leaf)){throw ('缺少文件：'+$file.Replace('/','\')+'。请重新完整解压压缩包。')}}
  foreach($path in @($appDir,$sourceDir,$dataDir)){Assert-WidgetNoReparsePoint $path}
  $package=Read-WidgetJsonFile (Join-Path $sourceDir 'package.json')
  if(!$package.version -or $package.version-notmatch '^\d+\.\d+\.\d+$'){throw 'package.json 版本无效。'}
  $startup=Get-WidgetKnownFolderPath ([Guid]'B97D20BB-F46A-4C97-BA10-5E3608430854');if(!$startup){throw '找不到 Windows 启动文件夹。'}
  $shortcut=Join-Path $startup 'Claude Niang.lnk'
  $config=[ordered]@{version=$package.version;appDir=$appDir;dataDir=$dataDir;webviewDir=$webviewDir;nodePath=$node.path;nodeVersion=$node.version;startupShortcut=$shortcut;installedAt=[DateTime]::UtcNow.ToString('o')}
  $info=Get-WidgetSupervisorInfo -AppDir $appDir -Configuration ([pscustomobject]$config)
  $null=Get-WidgetSupervisorTask $info
  if(Test-Path -LiteralPath $shortcut){
    $existing=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    if(!(Test-WidgetStartupShortcutIdentity -Shortcut $existing -AppDir $appDir)){throw '启动文件夹里已有另一个位置的 Claude 娘快捷方式。请先在原文件夹运行「停用Claude娘.cmd」。'}
  }
  foreach($directory in @($appDir,$dataDir,$startup)){Test-WidgetWritableDirectory $directory}
  return $config
}
