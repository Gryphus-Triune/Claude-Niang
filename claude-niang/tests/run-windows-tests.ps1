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
. (Join-Path $appDir 'runtime\claude-extras.ps1')
. (Import-Function (Join-Path $appDir 'widget.ps1') 'Write-WidgetJson')
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
  Case 'Settings save removes retired refresh and time-of-day settings' {
    . (Import-Function (Join-Path $appDir 'widget.ps1') 'Save-Settings')
    Save-Settings;$saved=Read-WidgetJsonFile $script:settingsFile
    Assert (!$saved.PSObject.Properties['pollMinutes']) 'Retired refresh setting persisted';Assert (!$saved.PSObject.Properties['peakTag']) 'Retired marker persisted'
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
