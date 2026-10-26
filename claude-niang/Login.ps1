param([switch]$Logout)
$ErrorActionPreference='Stop'
$appDir=$PSScriptRoot;$configPath=Join-Path $appDir 'installation.json'
if(!(Test-Path -LiteralPath $configPath)){Write-Host '请先运行「安装Claude娘.cmd」。' -ForegroundColor Red;exit 1}
$config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
$mode=if($Logout){'logout'}else{'login'}
$out=Join-Path $config.dataDir ($mode+'-result-'+[Guid]::NewGuid().ToString('N')+'.json')
$arguments=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $appDir 'runtime\claude-browser.ps1'),'-Mode',$mode,'-ConfigPath',$configPath,'-OutFile',$out)
if(!$Logout){Write-Host '登录窗口正在打开。登录后请点击角色或 ↻ 手动读取额度。'}
try{
  & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') @arguments|Out-Null
  $result=$null;try{$result=Get-Content -LiteralPath $out -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
  $success=$result -and $result.ok-eq $true -and $(if($Logout){$result.signedOut-eq $true}else{$result.signedIn-eq $true})
  if($success){
    $state=if($Logout){'signed-out'}else{'signed-in'}
    $record=@{id=[Guid]::NewGuid().ToString('N');at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();state=$state}|ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $config.dataDir 'session-reset.flag'),$record,[Text.UTF8Encoding]::new($false))
    if($Logout){Write-Host '已退出 Claude 娘里的登录（Claude 桌面端本身不受影响）。' -ForegroundColor Green}
    else{Write-Host '登录成功！点击角色或 ↻ 手动读取额度。' -ForegroundColor Green}
  }elseif($result.errorCode-eq 'BROWSER_BUSY'){Write-Host '内置浏览器正忙，请关闭已有登录窗口或等查询结束后再试。' -ForegroundColor Yellow;exit 1}
  elseif($result.error){Write-Host (('操作未完成：')+[string]$result.error) -ForegroundColor Red;exit 1}
  elseif($Logout){Write-Host '退出登录未成功，请重试。' -ForegroundColor Red;exit 1}
  else{Write-Host '登录窗口已关闭，没有检测到登录。' -ForegroundColor Yellow}
}finally{Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue}
