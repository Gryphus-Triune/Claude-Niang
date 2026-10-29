param([string]$ResultPath='')
$ErrorActionPreference='Stop'
$appDir=Split-Path $PSScriptRoot -Parent
$repoDir=Split-Path $appDir -Parent
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$scratch=Join-Path $tempBase ('cn-windows-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($scratch)
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert($Value,[string]$Message){if(!$Value){throw $Message}}
function Case([string]$Name,[scriptblock]$Run){
  try{& $Run;$results.Add([pscustomobject]@{name=$Name;passed=$true});Write-Host ('PASS '+$Name)}
  catch{$results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message) -ForegroundColor Red}
}
function Import-Function([string]$File,[string]$Name){
  $tokens=$null;$problems=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($File,[ref]$tokens,[ref]$problems)
  $node=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $Name},$true)
  if(!$node){throw ('Missing function '+$Name)}
  return [ScriptBlock]::Create($node.Extent.Text)
}
function Read-WidgetJsonFile([string]$File){if(Test-Path -LiteralPath $File){return Get-Content -LiteralPath $File -Raw -Encoding UTF8|ConvertFrom-Json};return $null}
. (Join-Path $appDir 'runtime\log.ps1')
. (Join-Path $appDir 'runtime\claude-extras.ps1')
foreach($name in @('Write-WidgetFileAtomic','Write-WidgetJson')){. (Import-Function (Join-Path $appDir 'runtime\common.ps1') $name)}
$script:dataDir=$scratch;$script:appDir=$appDir;$script:settingsFile=Join-Path $scratch 'settings.json'
$script:refreshCalls=0;$script:captured=@();$script:collapsed=$true
$script:window=[pscustomobject]@{IsVisible=$true};$script:context=[pscustomobject]@{IsOpen=$false}
function Request-Refresh {$script:refreshCalls++}
function Save-Settings {}
function Open-WidgetBubble([string]$Mode){$script:captured+=,$script:nextQuoteOverride;$script:collapsed=$false}
function Switch-Scene([string]$Mode){$script:captured+=,$script:nextQuoteOverride}
function Reset-WidgetAutoQuoteSchedule {}
function Finished-Process {$p=[pscustomobject]@{HasExited=$true};$p|Add-Member -MemberType ScriptMethod -Name Dispose -Value {};return $p}
function Reset-Notices {
  $script:noticeState=@{notified=@{};last=@{}};$script:noticeQueue=@();$script:noticeLastStamp='';$script:pendingNotice=$null;$script:captured=@();$script:collapsed=$true
}
function Set-Quota([string]$Account,[double]$Used,[long]$Stamp,[long]$Resets){
  $script:status=[pscustomobject]@{ok=$true;queryOk=$true;accountKey=$Account;observedAt=$Stamp;windows=@([pscustomobject]@{key='session';kind='session';label='5h';used=$Used;remaining=(100-$Used);resetsAt=$Resets})}
}
try{
  Case 'All PowerShell sources parse in Windows PowerShell' {
    foreach($f in @(Get-ChildItem -LiteralPath $repoDir -Filter '*.ps1' -Recurse -File)){
      $tokens=$null;$problems=$null;$null=[Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$problems)
      Assert (!$problems.Count) ('Syntax error '+$f.Name)
      $bytes=[IO.File]::ReadAllBytes($f.FullName)
      if(@($bytes|Where-Object{$_-gt 127}).Count){Assert ($bytes[0]-eq 239 -and $bytes[1]-eq 187 -and $bytes[2]-eq 191) ('UTF-8 BOM missing '+$f.Name)}
    }
  }
  Case 'Failed logout preserves current session and never claims success' {
    Reset-Notices;$script:refreshCalls=0;$script:status=[pscustomobject]@{ok=$true;windows=@('old')}
    $script:logoutResultFile=Join-Path $scratch 'failed-logout.json';Write-WidgetJson $script:logoutResultFile @{ok=$false;errorCode='BROWSER_BUSY'}
    $script:logoutProcess=Finished-Process;Tick-WidgetBrowserHelpers
    Assert $script:status.ok 'Existing quota was cleared on failure';Assert ($script:captured[-1]-like '*失败*') 'Missing failure message'
    Assert (!(Test-Path -LiteralPath (Join-Path $scratch 'session-reset.flag'))) 'Failure wrote a session reset';Assert ($script:refreshCalls-eq 0) 'Failure initiated a read'
  }
  Case 'Logout success requires signedOut and clears locally without reading' {
    Reset-Notices;$script:logoutResultFile=Join-Path $scratch 'success-logout.json';Write-WidgetJson $script:logoutResultFile @{ok=$true;signedOut=$true}
    $script:logoutProcess=Finished-Process;Tick-WidgetBrowserHelpers
    Assert (!$script:status.ok) 'Old quota survived logout';Assert ($script:status.errorCode-eq 'NOT_LOGGED_IN') 'Wrong signed-out state'
    Assert ((Read-WidgetJsonFile (Join-Path $scratch 'session-reset.flag')).state-eq 'signed-out') 'Missing typed session change';Assert ($script:refreshCalls-eq 0) 'Logout caused a read'
  }
  Case 'Missing logout result does not claim success' {
    Reset-Notices;$script:logoutResultFile=Join-Path $scratch 'missing-logout.json';$script:logoutProcess=Finished-Process
    Tick-WidgetBrowserHelpers;Assert ($script:captured[-1]-like '*失败*') 'Missing result was accepted'
  }
  Case 'Sign-in completion waits for manual quota request' {
    Reset-Notices;$script:loginResultFile=Join-Path $scratch 'success-login.json';Write-WidgetJson $script:loginResultFile @{ok=$true;signedIn=$true}
    $script:loginProcess=Finished-Process;Tick-WidgetBrowserHelpers
    Assert ($script:status.errorCode-eq 'MANUAL') 'Wrong signed-in state';Assert ($script:refreshCalls-eq 0) 'Sign-in initiated a quota read'
  }
  Case 'Organization choice hides previous quota and sends one explicit request' {
    $script:preferredOrg='aaaaaaaa-0000-4000-8000-000000000001'
    $script:status=[pscustomobject]@{ok=$true;selectedOrg=$script:preferredOrg;windows=@('old');orgs=@([pscustomobject]@{uuid='aaaaaaaa-0000-4000-8000-000000000002';name='Team';planLabel='Team'})}
    $script:refreshCalls=0;Set-WidgetPreferredOrg 'aaaaaaaa-0000-4000-8000-000000000002'
    Assert (!$script:status.ok -and $script:status.windows.Count-eq 0) 'Old quota still visible';Assert ($script:refreshCalls-eq 1) 'Selection did not send one request'
  }
  Case 'Sunglasses appear only for the calibrated picture' {
    if(!('ClaudeMusicGlasses' -as [type])){Add-Type -TypeDefinition 'public sealed class ClaudeMusicGlasses { public double X,Y,Span,Angle,FaceX,FaceY,FaceWidth,FaceHeight; }'}
    . (Import-Function (Join-Path $appDir 'runtime\music.ps1') 'Get-WidgetMusicGlasses')
    $picture=Join-Path $scratch 'glasses-test.png';[IO.File]::WriteAllBytes($picture,[byte[]](1..64))
    $sha=[Security.Cryptography.SHA256]::Create();$hash=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($picture))).Replace('-','').ToLowerInvariant();$sha.Dispose()
    Write-WidgetJson (Join-Path $scratch 'glasses-test.glasses.json') @{version=1;image=@{sha256=$hash};glasses=@{x=0.5;y=0.55;span=0.29;angle=-7};face=@{x=0.5;y=0.56;width=0.21;height=0.17}}
    $script:activeCharacter=[pscustomobject]@{id='claude-niang';path=$picture}
    $glasses=Get-WidgetMusicGlasses;Assert ($glasses -and $glasses.Span-eq 0.29 -and $glasses.Angle-eq -7) 'Calibrated picture lost its glasses'
    [IO.File]::WriteAllBytes($picture,[byte[]](2..65));Assert ($null-eq (Get-WidgetMusicGlasses)) 'Replaced picture still got glasses'
    $script:activeCharacter=$null
  }
  Case 'Showing a window does not request quota' {
    $tokens=$null;$problems=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $appDir 'widget.ps1'),[ref]$tokens,[ref]$problems)
    $node=$ast.Find({param($n)$n-is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text-eq '$showWidget'},$true)
    $script:window|Add-Member -MemberType ScriptMethod -Name Show -Value {$this.IsVisible=$true} -Force
    $script:followHost=$true;$script:refreshCalls=0;$body=$node.Clauses[0].Item2.Extent.Text
    . ([ScriptBlock]::Create($body.Substring(1,$body.Length-2)))
    Assert ($script:refreshCalls-eq 0) 'Visibility initiated a request'
  }
  Case 'A late old-organization file cannot overwrite a new UI selection' {
    $script:preferredOrg='aaaaaaaa-0000-4000-8000-000000000002'
    $script:status=[pscustomobject]@{ok=$true;selectedOrg='aaaaaaaa-0000-4000-8000-000000000001';windows=@('old');orgs=@()}
    Protect-WidgetSelectedOrganization
    Assert (!$script:status.ok -and $script:status.windows.Count-eq 0) 'Old result visible after selection'
    Assert ($script:status.selectedOrg-eq $script:preferredOrg) 'Selection changed back'
  }
  Case 'Quote save accepts 5000 rows and rejects overflow without replacing either saved copy' {
    . (Join-Path $appDir 'runtime\quotes.ps1')
    $data=Join-Path $scratch 'quote-count';$file=Join-Path $data 'quotes.json'
    $null=Save-WidgetQuotes $data @('original quote')
    $rows=@(1..5000|ForEach-Object{@{text=('quote '+$_);weight=1}})
    $saved=Save-WidgetQuotes $data $rows
    Assert ($saved.source-eq 'custom' -and !$saved.error -and $saved.quotes.Count-eq 5000) 'Valid boundary was not saved and read back'
    $before=[IO.File]::ReadAllText($file);$backup=[IO.File]::ReadAllText($file+'.bak')
    $failed=$false;try{$null=Save-WidgetQuotes $data ($rows+@{text='overflow';weight=1})}catch{$failed=$_.Exception.Message-like '*5000*'}
    Assert $failed '5001 quotes were accepted'
    Assert ([IO.File]::ReadAllText($file)-ceq $before) 'Rejected save replaced the current quotes'
    Assert ([IO.File]::ReadAllText($file+'.bak')-ceq $backup) 'Rejected save replaced the backup'
  }
  Case 'Quote size checks include UTF-8 bytes and the BOM before saving' {
    . (Join-Path $appDir 'runtime\quotes.ps1')
    $data=Join-Path $scratch 'quote-size';$file=Join-Path $data 'quotes.json'
    $null=Save-WidgetQuotes $data @('keep this quote');$before=[IO.File]::ReadAllText($file)
    $rows=@(1..2000|ForEach-Object{@{text=(('字'*190)+$_);weight=1}})
    $failed=$false;try{$null=Save-WidgetQuotes $data $rows}catch{$failed=$_.Exception.Message-like '*1 MB*'}
    Assert $failed 'A multi-byte file over 1 MB was accepted'
    Assert ([IO.File]::ReadAllText($file)-ceq $before) 'Oversized save replaced the previous list'
    Assert (!(Test-Path -LiteralPath ($file+'.bak'))) 'Oversized save created a backup before validation'
    $boundary=Join-Path $data 'boundary.json';$json='{"quotes":["boundary"]}'
    [IO.File]::WriteAllText($boundary,($json+(' '*(1MB-3-$json.Length))),[Text.UTF8Encoding]::new($true))
    Assert (@(Read-WidgetQuoteFile $boundary).Count-eq 1) 'Exactly 1 MB was rejected'
    [IO.File]::AppendAllText($boundary,' ',[Text.UTF8Encoding]::new($false))
    $failed=$false;try{$null=Read-WidgetQuoteFile $boundary}catch{$failed=$_.Exception.Message-like '*1 MB*'}
    Assert $failed 'A file above the read limit was accepted'
  }
  Case 'Quote save never reports success after falling back to built-in quotes' {
    . (Join-Path $appDir 'runtime\quotes.ps1')
    function Get-WidgetQuoteSettings([string]$DataDir){return [pscustomobject]@{source='built-in';quotes=@('fallback');error='cannot read'}}
    $failed=$false;try{$null=Save-WidgetQuotes (Join-Path $scratch 'quote-readback') @('new quote')}catch{$failed=$_.Exception.Message-like '*读回*'}
    Assert $failed 'Read-back failure was reported as a successful save'
  }
  Case 'Expired tooltip percentages are explicitly historical' {
    . (Import-Function (Join-Path $appDir 'runtime\widget-quota.ps1') 'Format-ResetTime')
    $previous=$script:status;$nowSeconds=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try{
      $script:status=[pscustomobject]@{windows=@([pscustomobject]@{kind='session';label='5 小时';remaining=63;resetsAt=$nowSeconds},[pscustomobject]@{kind='weekly';label='每周';remaining=80;resetsAt=($nowSeconds+3600)})}
      $lines=@(Get-WidgetClaudeDetailLines $nowSeconds)
      Assert ($lines[0]-like '*上次剩余 63%*重置已到*') 'Expired amount still looks current'
      Assert ($lines[1]-like '*：剩余 80%*' -and $lines[1]-notlike '*上次剩余*') 'Live quota was marked historical'
    }finally{$script:status=$previous}
  }
  Case 'Credit tooltip uses its own timestamp and preserves independent errors' {
    $previous=$script:status;$creditAt=1700000000000L
    try{
      $script:status=[pscustomobject]@{observedAt=($creditAt+1800000);credits=@{amountMinor=1234;currency='USD';observedAt=$creditAt};creditsStatus=@{state='cached';queryOk=$null}}
      $line=Get-WidgetCreditsDetailLine
      $expected=[DateTimeOffset]::FromUnixTimeMilliseconds($creditAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
      Assert ($line.Contains($expected) -and $line-like '*上次预付余额*$12.34*缓存*') 'Credit tooltip uses the quota timestamp or hides caching'
      $script:status.creditsStatus=@{state='error';queryOk=$false;error='余额网络错误'}
      $line=Get-WidgetCreditsDetailLine
      Assert ($line-like '*上次预付余额*$12.34*余额刷新失败*余额网络错误*') 'Old credit amount concealed the latest error'
      $script:status.credits=$null
      Assert ((Get-WidgetCreditsDetailLine)-eq '预付余额读取失败：余额网络错误 · 请手动刷新') 'Missing balance concealed the error'
    }finally{$script:status=$previous}
  }
  Case 'Credit tooltip labels old snapshots and shows the independent retry deadline' {
    $previous=$script:status;$creditNow=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try{
      $script:status=[pscustomobject]@{queryOk=$true;credits=@{amountMinor=500;currency='USD';observedAt=($creditNow-1800001)};creditsStatus=@{state='fresh';queryOk=$true}}
      Assert ((Get-WidgetCreditsDetailLine)-like '上次预付余额*缓存') 'A balance older than 30 minutes still looked fresh'
      $script:status.credits.Remove('observedAt')
      Assert ((Get-WidgetCreditsDetailLine)-like '上次预付余额*读取时间未知*缓存') 'A legacy balance without its own timestamp looked fresh'
      $script:status.creditsStatus=@{state='error';queryOk=$false;error='余额限流';retryAt=($creditNow+10800000)}
      $expected=[DateTimeOffset]::FromUnixTimeMilliseconds($creditNow+10800000).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
      $line=Get-WidgetCreditsDetailLine
      Assert ($line.Contains('请在 '+$expected+' 后手动刷新')) 'Balance retry deadline was not shown in local time'
      $script:status.creditsStatus.retryAt=$creditNow-1
      $line=Get-WidgetCreditsDetailLine
      Assert ($line-like '*请手动刷新' -and $line-notlike '*请在*') 'An elapsed retry deadline still asked the user to wait'
    }finally{$script:status=$previous}
  }
  Case 'A failed refresh remains visible when quota was restored from disk' {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    . (Join-Path $appDir 'runtime\widget-quota.ps1')
    function Update-BubbleTooltip {}
    $previous=@{dataDir=$script:dataDir;status=$script:status;preferredOrg=$script:preferredOrg;ui=$script:ui;quotaPage=$script:quotaPage;statusStamp=$script:statusStamp}
    try{
      $script:dataDir=Join-Path $scratch 'restored-display';$null=[IO.Directory]::CreateDirectory($script:dataDir)
      $script:preferredOrg=$null;$script:quotaPage=0;$script:statusStamp=0;$script:quotaRenderKey=$null;$script:ui=@{}
      foreach($prefix in @('Short','Week')){
        foreach($suffix in @('Label','Used','Left','Reset')){$script:ui[$prefix+$suffix]=[Windows.Controls.TextBlock]::new()}
        $script:ui[$prefix+'Row']=[Windows.Controls.Border]::new();$script:ui[$prefix+'Bar']=[Windows.Controls.Border]::new()
      }
      $script:ui.Status=[Windows.Controls.TextBlock]::new();$script:ui.Header=[Windows.Controls.TextBlock]::new();$script:ui.LiveDot=[Windows.Shapes.Ellipse]::new()
      Write-WidgetJson (Join-Path $script:dataDir 'status.json') @{ok=$true;queryOk=$false;restored=$true;observedAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeMilliseconds();error='网络暂时不可用';errorCode='NETWORK';windows=@()}
      Update-Quota
      Assert ($script:ui.Status.Text-like '刷新未成功：网络暂时不可用*上次*') 'Restored flag hid the current refresh failure'
      Write-WidgetJson (Join-Path $script:dataDir 'status.json') @{ok=$true;queryOk=$false;restored=$true;observedAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeMilliseconds();error='上次保存的额度，点 ↻ 手动刷新';errorCode=$null;windows=@()}
      $script:statusStamp=0;Update-Quota
      Assert ($script:ui.Status.Text-like '上次读取于*手动刷新' -and $script:ui.Status.Text-notlike '*刷新未成功*') 'Ordinary startup restore was displayed as a failed refresh'
    }finally{foreach($key in $previous.Keys){Set-Variable -Name $key -Scope Script -Value $previous[$key]};$script:quotaRenderKey=$null;$script:quotaRenderStatus=$null}
  }
  Case 'Settings save removes retired refresh and time-of-day settings' {
    . (Import-Function (Join-Path $appDir 'runtime\widget-settings.ps1') 'Save-Settings')
    Save-Settings;$saved=Read-WidgetJsonFile $script:settingsFile
    Assert (!$saved.PSObject.Properties['pollMinutes']) 'Retired refresh setting persisted';Assert (!$saved.PSObject.Properties['peakTag']) 'Retired marker persisted'
  }
  Case 'Settings fields are read one by one; a bad value keeps its default' {
    foreach($name in @('Get-WidgetSettingNumber','Get-WidgetSettingFlag','Import-WidgetSettings')){. (Import-Function (Join-Path $appDir 'runtime\widget-settings.ps1') $name)}
    $script:offsetRight=0.0;$script:offsetBottom=0.0;$script:offsetLeft=$null;$script:anchor='right';$script:side='right';$script:scale=1.0;$script:bubbleScale=1.0
    $script:soundOn=$true;$script:soundVolume=0.9;$script:followHost=$true;$script:characterId='claude-niang'
    $saved='{"layoutVersion":2,"right":"NaN","bottom":12.5,"scale":9,"bubbleScale":1.5,"left":-3,"anchor":"free","side":"up","soundOn":"yes","soundVolume":7,"followHost":false,"colorMode":"rainbow","colorChance":31,"characterId":"custom-x"}'|ConvertFrom-Json
    Import-WidgetSettings $saved
    Assert ($script:offsetRight-eq 0 -and $script:offsetBottom-eq 12.5 -and $script:offsetLeft-eq -3) 'Offsets not read one by one'
    Assert ($script:scale-eq 1 -and $script:bubbleScale-eq 1.5) 'Out-of-range size accepted'
    Assert ($script:anchor-eq 'free' -and $script:side-eq 'right') 'Anchor or side wrong'
    Assert ($script:soundOn-eq $false -and $script:soundVolume-eq 1) 'Sound settings wrong'
    Assert ($script:followHost-eq $false -and $null-eq $script:colorMode -and $script:characterId-eq 'custom-x') 'Other fields wrong'
    $script:offsetBottom=5;$script:anchor='right';Import-WidgetSettings ('{"right":30}'|ConvertFrom-Json)
    Assert ($script:offsetRight-eq 30 -and $script:offsetBottom-eq 0 -and $script:anchor-eq 'free') 'Old layout not migrated'
  }
  Case 'JSON replace waits out a short-lived reader and gives up on a lasting one' {
    if(!('CnTestCloser' -as [type])){Add-Type -TypeDefinition 'using System;using System.Threading;public static class CnTestCloser{public static void Later(IDisposable d,int ms){ThreadPool.QueueUserWorkItem(delegate{Thread.Sleep(ms);d.Dispose();});}}'}
    $target=Join-Path $scratch 'busy.json';Write-WidgetJson $target @{n=1}
    $reader=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);[CnTestCloser]::Later($reader,25)
    Write-WidgetJson $target @{n=2}
    Assert ((Read-WidgetJsonFile $target).n-eq 2) 'A short-lived reader blocked the write'
    $reader=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);$failed=$false
    try{Write-WidgetJson $target @{n=3}}catch{$failed=$true}finally{$reader.Dispose()}
    Assert $failed 'A lasting reader was not reported';Assert ((Read-WidgetJsonFile $target).n-eq 2) 'A blocked write changed the file'
    Assert (!@(Get-ChildItem -LiteralPath $scratch -Filter 'busy.json*.tmp').Count) 'Temporary file left behind'
  }
  Case 'Every state file is replaced through the one retrying writer' {
    $direct=@(Get-ChildItem -LiteralPath $appDir -Recurse -Filter '*.ps1'|Where-Object{$_.Name-ne 'common.ps1' -and $_.FullName-notlike '*\tests\*'}|Select-String -Pattern '::Replace\(' -SimpleMatch:$false)
    Assert (!$direct.Count) ('Direct File.Replace outside Write-WidgetFileAtomic: '+(($direct|ForEach-Object{$_.Filename+':'+$_.LineNumber})-join ', '))
  }
  Case 'Supervisor launcher runs PowerShell without a visible window and returns its exit code' {
    if(!('CnLaunchWindows' -as [type])){Add-Type -TypeDefinition @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public static class CnLaunchWindows{
  delegate bool P(IntPtr h,IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(P p,IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
  public static bool VisibleTitled(string title){bool found=false;EnumWindows((h,l)=>{var t=new StringBuilder(512);GetWindowText(h,t,512);if(IsWindowVisible(h)&&t.ToString().Contains(title))found=true;return true;},IntPtr.Zero);return found;}
}
'@}
    . (Join-Path $appDir 'runtime\supervisor-task.ps1')
    # A stand-in app folder: the real launcher source, and stand-in scripts that
    # title their console, stay alive briefly and exit with a known code.
    $app=Join-Path $scratch "launcher app O'Neil";$runtime=Join-Path $app 'runtime';$null=[IO.Directory]::CreateDirectory($runtime)
    Copy-Item -LiteralPath (Join-Path $appDir 'runtime\launcher.cs') -Destination $runtime
    $marker='cn-launch-'+[Guid]::NewGuid().ToString('N');$done=Join-Path $runtime 'done.txt';$opened=Join-Path $runtime 'opened.txt'
    [IO.File]::WriteAllText((Join-Path $runtime 'supervisor.ps1'),("`$host.UI.RawUI.WindowTitle='"+$marker+"';Start-Sleep -Milliseconds 2500;[IO.File]::WriteAllText('"+$done.Replace("'","''")+"','ok');exit 7"),[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $runtime 'start-supervisor.ps1'),("Start-Sleep -Milliseconds 1500;[IO.File]::WriteAllText('"+$opened.Replace("'","''")+"','ok')"),[Text.UTF8Encoding]::new($true))
    $launcher=Initialize-WidgetLauncher $app
    Assert ((Initialize-WidgetLauncher $app)-eq $launcher -and @(Get-ChildItem -LiteralPath $runtime|Where-Object{$_.Name-like 'claude-niang-launcher.exe.*'}).Count-eq 0) 'Unchanged launcher was rebuilt'
    $process=Start-Process -FilePath $launcher -ArgumentList 'supervisor' -PassThru
    $visible=$false;$deadline=[DateTime]::UtcNow.AddSeconds(20)
    while(!$process.HasExited -and [DateTime]::UtcNow-lt $deadline){if([CnLaunchWindows]::VisibleTitled($marker)){$visible=$true};Start-Sleep -Milliseconds 100}
    $finished=$process.WaitForExit(1000);$code=if($finished){$process.ExitCode}else{-1};$process.Dispose()
    Assert (Test-Path -LiteralPath $done) 'Launcher did not run the supervisor'
    Assert (!$visible) 'Supervisor console was visible'
    Assert ($code-eq 7) ('Launcher exit code '+$code)
    $open=Start-Process -FilePath $launcher -ArgumentList 'open' -PassThru
    Assert ($open.WaitForExit(1000)) 'open mode waited for start-supervisor';$open.Dispose()
    $deadline=[DateTime]::UtcNow.AddSeconds(15);while(!(Test-Path -LiteralPath $opened) -and [DateTime]::UtcNow-lt $deadline){Start-Sleep -Milliseconds 100}
    Assert (Test-Path -LiteralPath $opened) 'open mode did not run start-supervisor'
    # A changed source is rebuilt even while the old launcher is in use.
    $busy=Start-Process -FilePath $launcher -ArgumentList 'supervisor' -PassThru
    Add-Content -LiteralPath (Join-Path $runtime 'launcher.cs') -Value '// changed'
    $null=Initialize-WidgetLauncher $app
    $hash=[Diagnostics.FileVersionInfo]::GetVersionInfo($launcher).ProductVersion
    $null=$busy.WaitForExit(15000);$busy.Dispose()
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$expected=([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $runtime 'launcher.cs'))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    Assert ($hash-eq $expected) 'Changed launcher source was not rebuilt'
  }
  Case 'Supervisor registrations from this folder are recognized in both forms; others are refused' {
    . (Join-Path $appDir 'runtime\supervisor-task.ps1')
    $app=Join-Path $scratch 'App Folder';$other=Join-Path $scratch 'Other Folder'
    $current=@{Execute=($app+'\runtime\claude-niang-launcher.exe');Arguments='supervisor'}
    $legacy=@{Execute=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$app+'\runtime\supervisor.ps1"')}
    $vbs=@{Execute=(Join-Path $env:WINDIR 'System32\wscript.exe');Arguments=('//B //NoLogo "'+$app+'\runtime\supervisor.vbs"')}
    $headless=@{Execute=(Join-Path $env:WINDIR 'System32\conhost.exe');Arguments=(Get-WidgetHeadlessArguments $app)}
    Assert ((Get-WidgetSupervisorCommandKind $current.Execute $current.Arguments $app)-eq 'launcher') 'Launcher form not recognized'
    Assert ((Get-WidgetSupervisorCommandKind $headless.Execute $headless.Arguments $app)-eq 'headless') 'conhost form not recognized'
    Assert ((Get-WidgetSupervisorCommandKind $legacy.Execute $legacy.Arguments $app)-eq 'legacy') 'PowerShell form not recognized'
    Assert ((Get-WidgetSupervisorCommandKind $vbs.Execute $vbs.Arguments $app)-eq 'legacy') 'VBScript form not recognized'
    Assert ($null-eq (Get-WidgetSupervisorCommandKind $current.Execute $current.Arguments $other)) 'Another folder accepted'
    Assert (Test-WidgetStartupShortcutIdentity ([pscustomobject]@{TargetPath=$legacy.Execute;Arguments=$legacy.Arguments}) $app) 'Earlier shortcut treated as foreign'
    $info=[pscustomobject]@{AppDir=$app;TaskName='T';TaskPath='\';Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
    $launch=[pscustomobject]@{AppDir=$app;Kind='launcher'};$blocked=[pscustomobject]@{AppDir=$app;Kind='headless'}
    $task={param($action)[pscustomobject]@{TaskName='T';TaskPath='\';Principal=[pscustomobject]@{UserId=$info.Sid;LogonType='Interactive';RunLevel='Limited'};Actions=@([pscustomobject]$action)}}
    Assert (!(Test-WidgetSupervisorTaskCurrent (& $task $legacy) $launch)) 'Earlier task not marked for upgrade'
    Assert (Test-WidgetSupervisorTaskCurrent (& $task $current) $launch) 'Current task marked for upgrade'
    Assert (!(Test-WidgetSupervisorTaskCurrent (& $task $current) $blocked)) 'Launcher task kept although the launcher is blocked'
    Assert (Test-WidgetSupervisorTaskCurrent (& $task $headless) $blocked) 'conhost task marked for upgrade'
    Assert-WidgetSupervisorTaskIdentity (& $task $legacy) $info
    Assert-WidgetSupervisorTaskIdentity (& $task $headless) $info
    $refused=$false;try{Assert-WidgetSupervisorTaskIdentity (& $task @{Execute=($other+'\runtime\claude-niang-launcher.exe');Arguments='supervisor'}) $info}catch{$refused=$true}
    Assert $refused 'Another folder task accepted'
    $xml=New-WidgetSupervisorTaskXml -Info (Get-WidgetSupervisorInfo $appDir ([pscustomobject]@{appDir=$appDir;dataDir=$scratch})) -Account $info.Sid
    Assert ($xml-like '*claude-niang-launcher.exe</Command>*' -and $xml-like '*<Arguments>supervisor</Arguments>*') 'Task XML does not use the launcher'
  }
  Case 'A blocked launcher falls back to conhost, which also keeps the console hidden' {
    . (Join-Path $appDir 'runtime\supervisor-task.ps1')
    $app=Join-Path $scratch "launcher app O'Neil";$runtime=Join-Path $app 'runtime'
    $script:widgetSupervisorLaunch=$null
    Assert ((Resolve-WidgetSupervisorLaunch $app).Kind-eq 'launcher') 'Working launcher not chosen'
    # Policy refusing the program looks like a failed start.
    function Start-Process {throw 'This program is blocked by group policy.'}
    $script:widgetSupervisorLaunch=$null
    $launch=Resolve-WidgetSupervisorLaunch $app
    Remove-Item Function:\Start-Process;$script:widgetSupervisorLaunch=$null
    Assert ($launch.Kind-eq 'headless' -and $launch.Reason-like '*blocked*') ('Blocked launcher not replaced: '+$launch.Kind)
    Assert ((Get-WidgetSupervisorCommandKind $launch.Execute $launch.Arguments $app)-eq 'headless') 'Fallback command not recognized as ours'
    # Run the fallback command itself with the stand-in supervisor from the launcher case.
    $done=Join-Path $runtime 'done.txt';Remove-Item -LiteralPath $done -ErrorAction SilentlyContinue
    $marker=[IO.File]::ReadAllText((Join-Path $runtime 'supervisor.ps1'))-replace "^.*WindowTitle='([^']+)'.*$",'$1'
    $process=Start-Process -FilePath $launch.Execute -ArgumentList $launch.Arguments -PassThru
    $visible=$false;$deadline=[DateTime]::UtcNow.AddSeconds(20)
    while(!$process.HasExited -and [DateTime]::UtcNow-lt $deadline){if([CnLaunchWindows]::VisibleTitled($marker)){$visible=$true};Start-Sleep -Milliseconds 100}
    $null=$process.WaitForExit(2000);$process.Dispose()
    Assert (Test-Path -LiteralPath $done) 'conhost fallback did not run the supervisor'
    Assert (!$visible) 'conhost fallback showed the console'
  }
  Case 'Worker health follows its heartbeat counter, not the clock, and needs two misses' {
    foreach($name in @('Get-WidgetWorkerHealth','Ensure-QuotaWorker')){. (Import-Function (Join-Path $appDir 'widget.ps1') $name)}
    $saved=@{config=$script:config;dataDir=$script:dataDir}
    $data=Join-Path $scratch 'health';$null=[IO.Directory]::CreateDirectory($data);$script:dataDir=$data
    $script:config=@{nodePath=(Get-Process -Id $PID).Path}
    $status=Join-Path $data 'worker-status.json';$lock=Join-Path $data 'worker.lock'
    $started=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $beat={param($seq,$at)Write-WidgetJson $status @{pid=$PID;token='t1';startedAt=$started;at=$at;seq=$seq}}
    Write-WidgetJson $lock @{pid=$PID;token='t1';startedAt=$started}
    $script:kills=0;$script:starts=0
    function Start-Process {$script:starts++;$p=[pscustomobject]@{HasExited=$false};$p|Add-Member ScriptMethod Kill {$script:kills++;$this.HasExited=$true};$p|Add-Member ScriptMethod WaitForExit {param($ms)$true};$p|Add-Member ScriptMethod Dispose {};return $p}
    $script:worker=Start-Process;$script:starts=0
    $script:workerClock=[pscustomobject]@{ElapsedMilliseconds=20000};$script:lastWorkerProbe=$null;$script:lastWorkerStart=0;$script:workerMark=$null;$script:workerMisses=0
    $probe={param($ms)$script:workerClock.ElapsedMilliseconds=$ms;Ensure-QuotaWorker 0}
    & $beat 1 $started;& $probe 20000
    Assert ($script:kills-eq 0 -and $script:workerMisses-eq 0) 'Healthy worker not accepted'
    & $probe 25000
    Assert ($script:kills-eq 0 -and $script:workerMisses-eq 1) 'One probe without progress restarted the worker'
    # The clock jumped an hour: the heartbeat still advanced, so the worker is alive.
    & $beat 2 ($started+3600000);& $probe 30000
    Assert ($script:kills-eq 0 -and $script:workerMisses-eq 0) 'A clock change made a working worker look stuck'
    $held=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{& $beat 3 $started;& $probe 35000}finally{$held.Dispose()}
    Assert ($script:kills-eq 0 -and $script:workerMisses-eq 1) 'One unreadable status restarted the worker'
    & $probe 40000
    Assert ($script:kills-eq 0 -and $script:workerMisses-eq 0) 'Readable progress after a failed read not accepted'
    & $probe 45000;& $probe 50000
    Assert ($script:kills-eq 1 -and $script:starts-eq 1) ('Stuck worker not replaced after two misses: kills '+$script:kills+', starts '+$script:starts)
    Remove-Item Function:\Start-Process
    $log=[IO.File]::ReadAllText((Join-Path $data 'logs\claude-niang.log'))
    Assert ($log-like '*心跳没有前进*') 'Restart reason not logged'
    $script:config=$saved.config;$script:dataDir=$saved.dataDir;$script:worker=$null
  }
  Case 'Searched quote layouts are kept on disk and checked before reuse' {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\quote-layout.ps1'),[Text.Encoding]::UTF8)))
    $window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8))
    $box=$window.FindName('QuoteText');$data=Join-Path $scratch 'layouts';$store=Join-Path $data 'cache\quote-layouts.json'
    Initialize-WidgetQuoteLayouts $appDir $data
    Assert ($script:quoteLayoutHints.Count-ge 1) 'Reviewed built-in layouts not loaded'
    $text='这是一句自己写的语录，用来检查排版缓存。'
    $first=Get-WidgetQuoteLayout $text $box
    Assert (Test-Path -LiteralPath $store) 'Searched layout not stored'
    Initialize-WidgetQuoteLayouts $appDir $data
    $sw=[Diagnostics.Stopwatch]::StartNew();$again=Get-WidgetQuoteLayout $text $box;$sw.Stop()
    Assert ($again.fontSize-eq $first.fontSize -and $again.width-eq $first.width) 'Stored layout changed the result'
    # A stored layout that no longer fits is searched again and replaced.
    $broken=[IO.File]::ReadAllText($store)-replace '"fontSize":\d+','"fontSize":32'-replace '"width":\d+','"width":140'
    [IO.File]::WriteAllText($store,$broken);Initialize-WidgetQuoteLayouts $appDir $data
    $fixed=Get-WidgetQuoteLayout $text $box
    Assert ($fixed.fontSize-eq $first.fontSize -and $fixed.width-eq $first.width) 'Unfit stored layout was used'
    Assert ([IO.File]::ReadAllText($store)-like ('*"fontSize":'+$first.fontSize+'*')) 'Unfit stored layout not replaced'
    foreach($row in @(([IO.File]::ReadAllText((Join-Path $appDir 'assets\quote-layouts.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json).quotes)){
      $lines=if($row.display.Contains("`n")){($row.display-split "`n").Count}else{0}
      $null=Get-WidgetQuoteLayout $row.display $box $lines
    }
    Assert (@(([IO.File]::ReadAllText($store)|ConvertFrom-Json).entries).Count-eq 1) 'Built-in quotes with a reviewed layout were stored'
  }
  Case 'The widget restarts a missing supervisor, but not when it was stopped on purpose' {
    . (Import-Function (Join-Path $appDir 'widget.ps1') 'Ensure-WidgetSupervisor')
    $saved=@{dataDir=$script:dataDir;appDir=$script:appDir}
    $data=Join-Path $scratch 'watchdog';$null=[IO.Directory]::CreateDirectory($data);$script:dataDir=$data
    $script:userSid='test-'+[Guid]::NewGuid().ToString('N');$script:starts=0
    function Start-Process {$script:starts++}
    $script:workerClock=[pscustomobject]@{ElapsedMilliseconds=0};$script:lastSupervisorProbe=0;$script:lastSupervisorStart=$null
    $probe={param($ms)$script:workerClock.ElapsedMilliseconds=$ms;Ensure-WidgetSupervisor}
    & $probe 10000
    Assert ($script:starts-eq 0) 'Checked before 30 seconds'
    $running=[Threading.Mutex]::new($false,'Local\ClaudeNiangSupervisor-'+$script:userSid)
    try{& $probe 30000}finally{$running.Dispose()}
    Assert ($script:starts-eq 0) 'Running supervisor restarted'
    [IO.File]::WriteAllText((Join-Path $data 'supervisor-disabled.flag'),'disabled');& $probe 60000
    Assert ($script:starts-eq 0) 'Disabled supervisor restarted'
    Remove-Item -LiteralPath (Join-Path $data 'supervisor-disabled.flag');& $probe 90000
    Assert ($script:starts-eq 1) 'Missing supervisor not restarted'
    & $probe 120000
    Assert ($script:starts-eq 1) 'Restarted again within five minutes'
    & $probe 400000
    Assert ($script:starts-eq 2) 'Not restarted after five minutes'
    Remove-Item Function:\Start-Process
    Assert ([IO.File]::ReadAllText((Join-Path $data 'logs\claude-niang.log'))-like '*监督进程不在运行*') 'Restart not logged'
    $script:dataDir=$saved.dataDir;$script:appDir=$saved.appDir
  }
  Case 'The widget and the worker agree on the pipe name' {
    . (Import-Function (Join-Path $appDir 'widget.ps1') 'Get-WidgetWorkerPipeName')
    $saved=$script:dataDir;$script:dataDir=Join-Path $scratch "管道 O'Neil";$script:workerPipeName=$null
    $expected=& (Get-Command node.exe).Source --input-type=module -e ("import {workerEndpoint} from '"+([Uri](Join-Path $appDir 'runtime\shared.mjs')).AbsoluteUri+"';console.log(workerEndpoint(process.argv[1]))") $script:dataDir
    Assert ('\\.\pipe\'+(Get-WidgetWorkerPipeName)-eq $expected) ('Pipe names differ: '+$expected)
    $script:dataDir=$saved;$script:workerPipeName=$null
  }
  Case 'Compiled C# helpers are cached and reused' {
    # Both runs use child processes so this one never locks the cached DLL.
    $cache=Join-Path $scratch 'types';$name='CnCacheProbe'+[Guid]::NewGuid().ToString('N')
    $source='public static class '+$name+' { public static int Value(){ return 42; } }'
    $quote={param($text)"'"+([string]$text).Replace("'","''")+"'"}
    $load='. '+(& $quote (Join-Path $appDir 'runtime\common.ps1'))+';Add-WidgetType -TypeName '+$name+' -TypeDefinition '+(& $quote $source)+' -CacheDirectory '+(& $quote $cache)+';['+$name+']::Value()'
    $powerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $first=@(& $powerShell -NoProfile -Command $load)
    Assert ($first[0]-eq '42') ('Type not usable: '+($first-join ','))
    $files=@(Get-ChildItem -LiteralPath $cache -Filter ($name+'-*.dll'))
    Assert ($files.Count-eq 1) 'Compiled helper not cached'
    $before=$files[0].LastWriteTimeUtc
    $again=@(& $powerShell -NoProfile -Command $load)
    Assert ($again[0]-eq '42') ('Cached helper not usable: '+($again-join ','))
    Assert ((Get-Item -LiteralPath $files[0].FullName).LastWriteTimeUtc-eq $before) 'Cached helper compiled again'
  }
  Case 'The Startup shortcut uses the conhost fallback, independent of the launcher' {
    . (Join-Path $appDir 'runtime\supervisor-task.ps1')
    $lnk=Join-Path $scratch 'startup-test.lnk';$app=Join-Path $scratch 'App Folder'
    Set-WidgetStartupShortcut $lnk $app
    $link=(New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    Assert ((Get-WidgetSupervisorCommandKind $link.TargetPath $link.Arguments $app)-eq 'headless') ('Shortcut form: '+$link.TargetPath+' '+$link.Arguments)
  }
  Case 'Only the five most recent removed pictures are kept' {
    . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir 'runtime\characters.ps1'),[Text.Encoding]::UTF8)))
    foreach($name in @('Write-WidgetFileAtomic')){. (Import-Function (Join-Path $appDir 'runtime\common.ps1') $name)}
    $data=Join-Path $scratch 'removed';$pictures=Join-Path $data 'characters';$bin=Join-Path $pictures 'removed'
    $null=[IO.Directory]::CreateDirectory($bin)
    $ids=@(1..7|ForEach-Object{'custom-'+[Guid]::NewGuid().ToString('N')})
    $removed=@(for($i=0;$i-lt 5;$i++){[IO.File]::WriteAllBytes((Join-Path $bin ($ids[$i]+'.png')),[byte[]](1,2,3));[pscustomobject]@{id=$ids[$i];name=('old '+$i);file=($ids[$i]+'.png');removedAt=('2026-01-0'+($i+1)+'T00:00:00Z')}})
    [IO.File]::WriteAllBytes((Join-Path $pictures ($ids[6]+'.png')),[byte[]](1,2,3))
    Write-WidgetCharacterCatalog (Join-Path $data 'characters.json') ([pscustomobject]@{version=1;characters=@([pscustomobject]@{id=$ids[6];name='new';file=($ids[6]+'.png')});removed=$removed})
    $null=Remove-WidgetCharacter $data $ids[6]
    $catalog=Read-WidgetCharacterCatalog (Join-Path $data 'characters.json')
    Assert (@($catalog.removed).Count-eq 5) ('Removed list size '+@($catalog.removed).Count)
    Assert (!(Test-Path -LiteralPath (Join-Path $bin ($ids[0]+'.png')))) 'Oldest removed picture kept'
    Assert ((Test-Path -LiteralPath (Join-Path $bin ($ids[6]+'.png'))) -and (Test-Path -LiteralPath (Join-Path $bin ($ids[1]+'.png')))) 'Recent removed pictures deleted'
  }
  Case 'Diagnostic log merges repeats and rolls over at 1 MB' {
    $logDir=Join-Path $scratch 'log-test';$file=Join-Path $logDir 'logs\claude-niang.log'
    Write-WidgetLog $logDir 'widget' '第一条';Write-WidgetLog $logDir 'widget' '第一条'
    $first=@(Get-Content -LiteralPath $file -Encoding UTF8)
    Assert ($first.Count-eq 1) 'Repeat not merged'
    Assert ($first[0]-match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} [+-]\d\d:\d\d \[widget \d+\] 第一条$') ('Line format: '+$first[0])
    $stream=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Write);try{$stream.SetLength(1MB)}finally{$stream.Dispose()}
    Write-WidgetLog $logDir 'widget' '第二条'
    Assert ((Get-Item -LiteralPath (Join-Path $logDir 'logs\claude-niang.1.log')).Length-ge 1MB) 'Old log not kept'
    Assert (@(Get-Content -LiteralPath $file -Encoding UTF8)[0]-like '*第二条') 'New log not started'
  }
  $a=('a'*64);$b=('b'*64);$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$future=[DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds()
  Case 'Switching organizations never produces a false reset' {
    Reset-Notices;Set-Quota $a 90 $now $future;Tick-WidgetClaudeNotices $true
    $script:noticeQueue=@();Set-Quota $b 2 ($now+1) ($future+1000);Tick-WidgetClaudeNotices $true
    Assert ($script:noticeQueue.Count-eq 0) 'Cross-organization false reset';Assert ($script:captured.Count-eq 0) 'Unexpected reminder'
  }
  Case 'Two alerts are queued and marked only when actually displayed' {
    Reset-Notices;Set-Quota $a 90 $now $future
    $script:status.windows+=,[pscustomobject]@{key='weekly';kind='weekly';label='Week';used=95;remaining=5;resetsAt=($future+604800)}
    $script:context.IsOpen=$true;Tick-WidgetClaudeNotices $true
    Assert ($script:noticeState.notified.Count-eq 0) 'Hidden alerts were marked shown';Assert ($script:noticeQueue[0].keys.Count-eq 2) 'An alert was lost'
    $script:context.IsOpen=$false;Tick-WidgetClaudeNotices $true
    Assert ($script:noticeState.notified.Count-eq 2) 'Shown alerts not recorded';Assert ($script:captured[-1]-like '*5h*' -and $script:captured[-1]-like '*Week*') 'Combined message incomplete'
  }
  Case 'Restored or failed snapshots never create new reminders' {
    Reset-Notices;Set-Quota $a 99 $now $future;$script:status.queryOk=$false;Tick-WidgetClaudeNotices $true
    Assert ($script:noticeQueue.Count-eq 0) 'Failed read created an alert'
  }
  Case 'Custom audio imports a valid bundled wave and reports missing converter accurately' {
    foreach($name in @('Import-WidgetAudio','Copy-WidgetAudioPreferences','Read-WidgetPcmWave')){. (Import-Function (Join-Path $appDir 'runtime\audio.ps1') $name)}
    function Set-WidgetAudioPreferences($Preferences,[string]$RequiredSlot){$script:claudeNiangAudio.Preferences=$Preferences}
    function Remove-WidgetUnusedAudioFiles($Audio,$Preferences){}
    $script:config=@{nodePath=(Get-Command node.exe -ErrorAction Stop).Source}
    $script:claudeNiangAudio=@{AppDir=$appDir;DataDir=$scratch;Preferences=@{mode='builtin';press=$null;release=$null}}
    Assert (Import-WidgetAudio 'press' (Join-Path $appDir 'assets\press.wav')) 'Audio import failed'
    $target=Join-Path $scratch ('sounds\'+$script:claudeNiangAudio.Preferences.press.file)
    Assert ((Read-WidgetPcmWave $target).Duration-gt 0) 'Imported wave invalid'
    $script:claudeNiangAudio.AppDir=$scratch;$reason=''
    try{$null=Import-WidgetAudio 'press' (Join-Path $appDir 'assets\press.wav')}catch{$reason=$_.Exception.Message}
    Assert ($reason-like '*转换组件*') 'Missing converter misreported'
  }
  Case 'Both native helper sources compile with bundled SDK' {
    $sdk=Join-Path $appDir 'runtime\webview2'
    foreach($name in @('claude-browser','claude-host')){
      $provider=New-Object Microsoft.CSharp.CSharpCodeProvider
      try{
        $p=New-Object System.CodeDom.Compiler.CompilerParameters;$p.GenerateInMemory=$false;$p.OutputAssembly=Join-Path $scratch ($name+'.dll')
        foreach($reference in @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll',(Join-Path $sdk 'Microsoft.Web.WebView2.Core.dll'),(Join-Path $sdk 'Microsoft.Web.WebView2.WinForms.dll'))){$null=$p.ReferencedAssemblies.Add($reference)}
        $compiled=$provider.CompileAssemblyFromFile($p,[string[]]@((Join-Path $appDir ('runtime\'+$name+'.cs'))))
        Assert (!$compiled.Errors.HasErrors) (($compiled.Errors|ForEach-Object{[string]$_})-join '; ')
      }finally{$provider.Dispose()}
    }
  }
  Case 'Clean release excludes machine data and starts from a new path' {
    $out=Join-Path $scratch "发布 测试 O'Neil"
    & (Join-Path $repoDir 'build-release.ps1') -OutDir $out
    Assert ($LASTEXITCODE-eq 0) 'Build failed'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=@(Get-ChildItem -LiteralPath $out -Filter '*.zip')[0]
    $extract=Join-Path $scratch "全新 安装 O'Neil";[IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName,$extract)
    $clean=Join-Path $extract 'Claude娘额度挂件\claude-niang'
    foreach($name in @('installation.json','install-log.txt','claude-desktop-mcp.json')){Assert (!(Test-Path -LiteralPath (Join-Path $clean $name))) ('Machine file packaged: '+$name)}
    . (Join-Path $clean 'runtime\common.ps1');. (Join-Path $clean 'runtime\supervisor-task.ps1');. (Join-Path $clean 'runtime\install-preflight.ps1')
    function Get-WidgetLocalApplicationData {return (Join-Path $scratch 'User Local')}
    function Get-WidgetKnownFolderPath([Guid]$Id){return (Join-Path $scratch 'Startup')}
    function Get-WidgetSupervisorTask($Info){return $null}
    function Find-WidgetNode {$node=(Get-Command node.exe).Source;return [pscustomobject]@{path=$node;version=(& $node --version)}}
    $null=[IO.Directory]::CreateDirectory((Join-Path $scratch 'Startup'))
    $config=Get-WidgetInstallPreflight -SourceDir $clean -AppDir $clean
    Assert ($config.appDir-eq $clean) 'Fresh install uses wrong app path';Assert ($config.dataDir.StartsWith($scratch)) 'Fresh install used real profile'
    Write-WidgetSupervisorJson (Join-Path $clean 'installation.json') $config
    $check=Join-Path $scratch 'widget-check.json';$errorFile=Join-Path $scratch 'widget-check-error.txt'
    $launchArgs=@('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $clean 'widget.ps1')+'"'),'-CheckOnly','-AppDir',('"'+$clean+'"'))
    $startInfo=[Diagnostics.ProcessStartInfo]::new();$startInfo.FileName=Get-WidgetPowerShellPath;$startInfo.Arguments=$launchArgs-join ' '
    $startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true;$startInfo.RedirectStandardOutput=$true;$startInfo.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$startInfo
    try{
      Assert ($process.Start()) 'Widget check did not start';Assert ($process.WaitForExit(45000)) 'Widget check timed out'
      $raw=$process.StandardOutput.ReadToEnd();$errorText=$process.StandardError.ReadToEnd()
      [IO.File]::WriteAllText($check,$raw);[IO.File]::WriteAllText($errorFile,$errorText)
      Assert ($process.ExitCode-eq 0) ('Widget exited '+$process.ExitCode+': '+$errorText)
      $smoke=$raw|ConvertFrom-Json;Assert $smoke.ok 'Widget startup failed';Assert $smoke.imageLoaded 'Default image missing'
    }finally{if(!$process.HasExited){$process.Kill()};$process.Dispose()}
    Assert (!(Test-Path -LiteralPath (Join-Path $config.dataDir 'worker-status.json'))) 'Check-only started quota worker'
  }
}finally{
  $summary=[pscustomobject]@{tests=$results.Count;passed=@($results|Where-Object{$_.passed}).Count;failed=@($results|Where-Object{!$_.passed}).Count;results=$results.ToArray()}
  if($ResultPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath),($summary|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
  $summary|ConvertTo-Json -Depth 8
  $resolved=[IO.Path]::GetFullPath($scratch)
  if($resolved.StartsWith($tempBase+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved)-match '^cn-windows-[a-f0-9]{32}$'){
    # Keep failure evidence in the isolated temp directory; clean only success.
    if($summary.failed-eq 0){Remove-Item -LiteralPath $resolved -Recurse -Force}else{Write-Host ('Failure details: '+$resolved)}
  }
}
if($summary.failed){exit 1}
