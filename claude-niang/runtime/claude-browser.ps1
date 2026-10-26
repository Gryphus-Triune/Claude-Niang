param(
  [ValidateSet('fetch','login','logout','check')][string]$Mode='fetch',
  [string]$ConfigPath='',
  [string]$OutFile='',
  [string]$PreferredOrg='',
  [switch]$IncludeCredits,
  [switch]$AllowBootstrap,
  [string]$OrgId='',
  [switch]$SkipOrganizations,
  [int]$TimeoutSeconds=60
)
# Claude娘的小浏览器（Microsoft Edge WebView2）。
#  fetch  ：后台读取 claude.ai 的组织与额度（只读，页面脚本关闭，不自动处理网页验证）
#           组织列表变化很少：带 -SkipOrganizations -OrgId 时只读这一个组织的额度
#  login  ：打开可见的登录窗口，用户自己登录一次
#  logout ：清除这个小浏览器里的登录状态
#  check  ：检查 WebView2 运行时与组件
# 输出始终是一段 JSON（写到 -OutFile，或标准输出）。不输出 Cookie 或令牌。
$ErrorActionPreference='Stop'
$started=[Diagnostics.Stopwatch]::StartNew()
$utf8=[Text.UTF8Encoding]::new($false)

function Write-BrowserResult($Value){
  $Value['v']=1;$Value['mode']=$Mode;$Value['durationMs']=[int]$started.ElapsedMilliseconds
  $json=$Value|ConvertTo-Json -Depth 8 -Compress
  if($OutFile){
    $directory=[IO.Path]::GetDirectoryName($OutFile)
    if($directory){[IO.Directory]::CreateDirectory($directory)|Out-Null}
    $temp=$OutFile+'.tmp'
    [IO.File]::WriteAllText($temp,$json,$utf8)
    if([IO.File]::Exists($OutFile)){[IO.File]::Delete($OutFile)}
    [IO.File]::Move($temp,$OutFile)
  }else{
    [Console]::OutputEncoding=$utf8
    [Console]::Out.Write($json)
  }
}

function Get-BrowserProfileDir {
  if($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)){
    try{
      $config=[IO.File]::ReadAllText($ConfigPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
      if($config.webviewDir){return [IO.Path]::GetFullPath([string]$config.webviewDir)}
      if($config.dataDir){return [IO.Path]::GetFullPath((Join-Path (Split-Path ([string]$config.dataDir) -Parent) 'webview'))}
    }catch{}
  }
  return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ClaudeNiang\webview')
}

function Initialize-BrowserTypes {
  $sdk=Join-Path $PSScriptRoot 'webview2'
  $core=Join-Path $sdk 'Microsoft.Web.WebView2.Core.dll'
  $forms=Join-Path $sdk 'Microsoft.Web.WebView2.WinForms.dll'
  foreach($file in @($core,$forms,(Join-Path $PSScriptRoot 'claude-browser.cs'))){
    if(!(Test-Path -LiteralPath $file)){throw [IO.FileNotFoundException]::new('missing '+$file)}
  }
  # A downloaded ZIP marks these DLLs as "from the internet" and .NET then refuses
  # to load them (0x80131515). The installer clears the mark; repeat it here for
  # files replaced later. Unmarked files are left as they are.
  foreach($file in @(Get-ChildItem -LiteralPath $sdk -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue)){try{Unblock-File -LiteralPath $file.FullName -ErrorAction Stop}catch{}}
  Add-Type -AssemblyName System.Windows.Forms,System.Drawing
  if(!('ClaudeNiangAssemblyResolver' -as [type])){
    Add-Type -IgnoreWarnings -TypeDefinition @'
using System;using System.IO;using System.Reflection;
public static class ClaudeNiangAssemblyResolver {
 static string folder;
 public static void Register(string sdk){
  if(folder!=null)return;
  folder=sdk;
  AppDomain.CurrentDomain.AssemblyResolve+=Resolve;
 }
 static Assembly Resolve(object sender,ResolveEventArgs e){
  string name=new AssemblyName(e.Name).Name;
  if(!name.StartsWith("Microsoft.Web.WebView2",StringComparison.OrdinalIgnoreCase))return null;
  string path=Path.Combine(folder,name+".dll");
  return File.Exists(path)?Assembly.LoadFrom(path):null;
 }
}
'@
  }
  [ClaudeNiangAssemblyResolver]::Register($sdk)
  $null=[Reflection.Assembly]::LoadFrom($core)
  $null=[Reflection.Assembly]::LoadFrom($forms)
  if(!('ClaudeNiangWeb' -as [type])){
    $references=@('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll',$core,$forms)
    Import-BrowserHelperAssembly (Join-Path $PSScriptRoot 'claude-browser.cs') $references
  }
  [ClaudeNiangWeb]::PrepareLoader($sdk)
}

# Each quota read is a short-lived PowerShell. Compile the helper once and keep
# the DLL (keyed by the source), instead of running the C# compiler every read.
# Any problem with the cached copy falls back to the plain in-memory Add-Type.
function Import-BrowserHelperAssembly([string]$Source,[string[]]$References){
  $cacheDir=Join-Path (Split-Path $profileDir -Parent) 'cache'
  $temp=$null
  try{
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
      $seed=[Text.Encoding]::UTF8.GetBytes(([Environment]::Version.ToString())+'|'+($References-join '|')+'|'+([IO.FileInfo]::new($References[-2])).Length+'|')
      $bytes=[byte[]]($seed+[IO.File]::ReadAllBytes($Source))
      $key=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').Substring(0,24).ToLowerInvariant()
    }finally{$sha.Dispose()}
    $cached=Join-Path $cacheDir ('claude-browser-'+$key+'.dll')
    if(!(Test-Path -LiteralPath $cached)){
      $null=[IO.Directory]::CreateDirectory($cacheDir)
      $temp=Join-Path $cacheDir ('build-'+[Guid]::NewGuid().ToString('N')+'.dll')
      $provider=New-Object Microsoft.CSharp.CSharpCodeProvider
      try{
        $parameters=New-Object System.CodeDom.Compiler.CompilerParameters
        $parameters.GenerateInMemory=$false;$parameters.GenerateExecutable=$false;$parameters.OutputAssembly=$temp;$parameters.TreatWarningsAsErrors=$false
        foreach($reference in $References){$null=$parameters.ReferencedAssemblies.Add($reference)}
        $results=$provider.CompileAssemblyFromFile($parameters,[string[]]@($Source))
      }finally{$provider.Dispose()}
      if(!$results.Errors.HasErrors -and (Test-Path -LiteralPath $temp)){
        # Another helper may have finished first; either copy is identical.
        try{[IO.File]::Move($temp,$cached)}catch{}
        foreach($old in @(Get-ChildItem -LiteralPath $cacheDir -Filter 'claude-browser-*.dll' -ErrorAction SilentlyContinue)){
          if($old.FullName-ine $cached){try{Remove-Item -LiteralPath $old.FullName -ErrorAction Stop}catch{}}
        }
      }
    }
    if(Test-Path -LiteralPath $cached){
      try{$null=[Reflection.Assembly]::LoadFrom($cached)}
      catch{Remove-Item -LiteralPath $cached -ErrorAction SilentlyContinue}
    }
  }catch{
  }finally{
    if($temp){Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}
  }
  if(!('ClaudeNiangWeb' -as [type])){
    Add-Type -Path $Source -ReferencedAssemblies $References -IgnoreWarnings
  }
}

function Get-BrowserErrorCode([string]$Message){
  if($Message-match 'WebView2RuntimeNotFound|compatible Webview2 Runtime|0x80070002') {return 'NO_WEBVIEW2'}
  if($Message-match 'timed out'){return 'TIMEOUT'}
  return 'BROWSER_ERROR'
}

function ConvertTo-RequestRecord($Response){
  return @{url=$Response.Url;status=$Response.Status;contentType=$Response.ContentType;cfMitigated=$Response.CfMitigated;retryAfter=$Response.RetryAfter;body=$Response.Body;bodyEncoding=$Response.BodyEncoding;error=$Response.Error}
}

function Read-ResponseJson($Response){
  if($Response.Status-lt 200 -or $Response.Status-ge 300 -or !$Response.Body){return $null}
  try{
    $text=$Response.Body
    if($Response.BodyEncoding-eq 'json-string'){$text=$text|ConvertFrom-Json}
    return ($text|ConvertFrom-Json)
  }catch{return $null}
}

# The profile is used by one helper at a time; a fetch never waits for the
# visible login window.
$profileDir=Get-BrowserProfileDir
$lockStream=$null
function Enter-BrowserLock {
  $null=[IO.Directory]::CreateDirectory($profileDir)
  try{
    $script:lockStream=[IO.File]::Open(($profileDir.TrimEnd('\')+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    return $true
  }catch{return $false}
}

try{
  if($Mode-eq 'check'){
    try{Initialize-BrowserTypes}catch{Write-BrowserResult @{ok=$false;errorCode='NO_SDK';error=$_.Exception.Message};exit 1}
    $version=[ClaudeNiangWeb]::RuntimeVersion()
    if(!$version){Write-BrowserResult @{ok=$false;errorCode='NO_WEBVIEW2';error='WebView2 runtime not found'};exit 1}
    Write-BrowserResult @{ok=$true;runtimeVersion=$version;profileDir=$profileDir;architecture=[ClaudeNiangWeb]::Architecture()};exit 0
  }

  try{Initialize-BrowserTypes}catch{Write-BrowserResult @{ok=$false;errorCode='NO_SDK';error=$_.Exception.Message};exit 1}
  $runtime=[ClaudeNiangWeb]::RuntimeVersion()
  if(!$runtime){Write-BrowserResult @{ok=$false;errorCode='NO_WEBVIEW2';error='WebView2 runtime not found'};exit 1}
  $lockDeadline=[DateTime]::UtcNow.AddSeconds($(if($Mode-in @('login','logout')){30}else{0}))
  $locked=Enter-BrowserLock
  while(!$locked -and [DateTime]::UtcNow-lt $lockDeadline){Start-Sleep -Milliseconds 150;$locked=Enter-BrowserLock}
  if(!$locked){Write-BrowserResult @{ok=$false;errorCode='BROWSER_BUSY';error='内置浏览器正忙，请关闭已有登录窗口或等查询结束后再试'};exit 1}
  [ClaudeNiangWeb]::EnableDpiAwareness()
  $timeout=[Math]::Max(10,$TimeoutSeconds)*1000

  if($Mode-eq 'login'){
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=[ClaudeNiangLoginForm]::new($profileDir,'https://claude.ai/login')
    [Windows.Forms.Application]::Run($form)
    Write-BrowserResult @{ok=[bool]$form.SignedIn;signedIn=[bool]$form.SignedIn;error=$form.Failure;runtimeVersion=$runtime}
    exit 0
  }

  $session=$null
  try{
    $session=[ClaudeNiangWebSession]::Open($profileDir,$timeout)
    if($Mode-eq 'logout'){
      $session.SignOut(15000)
      Write-BrowserResult @{ok=$true;signedOut=$true;runtimeVersion=$runtime}
      exit 0
    }
    # fetch
    $cookies=$session.Cookies(15000)
    $result=@{ok=$true;runtimeVersion=$runtime;session=@{hasSessionCookie=[bool]$cookies.HasSessionCookie;lastActiveOrg=[string]$cookies.LastActiveOrg};requests=@{}}
    if(!$cookies.HasSessionCookie){Write-BrowserResult $result;exit 0}
    $selected=$null
    if($SkipOrganizations -and $OrgId-match '^[0-9a-fA-F-]{8,64}$'){
      # The reader already knows the organization (its list is cached).
      $selected=[pscustomobject]@{uuid=$OrgId;capabilities=@('cached')}
    }else{
      $orgs=$session.Get('https://claude.ai/api/organizations',$timeout)
      $result.requests['organizations']=ConvertTo-RequestRecord $orgs
      $list=@(Read-ResponseJson $orgs)
      $list=@($list|Where-Object{$_ -and $_.uuid -is [string] -and $_.uuid-match '^[0-9a-fA-F-]{8,64}$'})
      if($list.Count-eq 0){Write-BrowserResult $result;exit 0}
      foreach($candidate in @($PreferredOrg,[string]$cookies.LastActiveOrg)){
        if(!$candidate){continue}
        $selected=@($list|Where-Object{$_.uuid-eq $candidate})[0]
        if($selected){break}
      }
      if($PreferredOrg -and (!$selected -or $selected.uuid-ne $PreferredOrg)){
        $result['selectedOrg']=$PreferredOrg;$result['errorCode']='ORG_UNAVAILABLE'
        Write-BrowserResult $result;exit 0
      }
      if(!$selected){$selected=@($list|Where-Object{@($_.capabilities)|Where-Object{[string]$_-match '^(chat|claude_)'}})[0]}
      if(!$selected){$selected=$list[0]}
    }
    $result['selectedOrg']=[string]$selected.uuid
    $usage=$session.Get(('https://claude.ai/api/organizations/'+$selected.uuid+'/usage'),$timeout)
    $result.requests['usage']=ConvertTo-RequestRecord $usage
    $usageJson=Read-ResponseJson $usage
    $extraEnabled=$usageJson -and (($usageJson.spend -and $usageJson.spend.enabled) -or ($usageJson.extra_usage -and $usageJson.extra_usage.is_enabled))
    if($IncludeCredits -and $extraEnabled){
      $credits=$session.Get(('https://claude.ai/api/organizations/'+$selected.uuid+'/prepaid/credits'),$timeout)
      $result.requests['credits']=ConvertTo-RequestRecord $credits
    }
    if($AllowBootstrap -and $null-eq $selected.capabilities){
      $bootstrap=$session.Get(('https://claude.ai/api/bootstrap/'+$selected.uuid+'/app_start'),$timeout)
      $result.requests['bootstrap']=ConvertTo-RequestRecord $bootstrap
    }
    Write-BrowserResult $result
    exit 0
  }finally{if($session){$session.Dispose()}}
}catch{
  $message=$_.Exception.ToString()
  try{Write-BrowserResult @{ok=$false;errorCode=(Get-BrowserErrorCode $message);error=$_.Exception.Message}}catch{}
  exit 1
}finally{
  if($lockStream){$lockStream.Dispose()}
}
