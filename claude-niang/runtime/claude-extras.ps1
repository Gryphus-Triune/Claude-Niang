# Claude 专属功能：登录窗口、手动读取、额度分页、低额度/重置提醒、
# 今日已用与本周节奏（借鉴小鲸鱼记账）。界面仍沿用 GPT 娘的气泡与两行额度布局。
$script:quotaPage=0
$script:preferredOrg=$null
$script:lowQuotaAlert=$true
$script:resetAlert=$true
$script:loginProcess=$null;$script:loginResultFile=$null;$script:logoutProcess=$null;$script:logoutResultFile=$null
$script:noticeState=$null;$script:noticeLastStamp="";$script:noticeQueue=@();$script:pendingNotice=$null;$script:nextQuoteOverride=$null

# --- colours (Claude 暖陶土色) ------------------------------------------------
$script:claudeInk=@{normal='#A2593F';warn='#9A6A12';danger='#B23B2E';muted='#A3958C'}
$script:claudeBar=@{normal='#D9825F';warn='#D9A441';danger='#D8604A';muted='#C9BCB3'}
function Get-WidgetQuotaTone($Window,[long]$NowSeconds){
  if(!$Window){return 'muted'}
  if($null-ne $Window.resetsAt -and [double]$Window.resetsAt-gt 0 -and [double]$Window.resetsAt-le $NowSeconds){return 'muted'}
  if($null-eq $Window.used){return 'muted'}
  $used=[double]$Window.used
  if($used-ge 90){return 'danger'}
  if($used-ge 75){return 'warn'}
  return 'normal'
}

function Initialize-WidgetClaudeSettings($Settings){
  if($null-ne $Settings){
    if($Settings.preferredOrg-is [string] -and $Settings.preferredOrg-match '^[0-9a-fA-F-]{8,64}$'){$script:preferredOrg=$Settings.preferredOrg}
    if($Settings.lowQuotaAlert-is [bool]){$script:lowQuotaAlert=$Settings.lowQuotaAlert}
    if($Settings.resetAlert-is [bool]){$script:resetAlert=$Settings.resetAlert}
  }
  $script:noticeState=Read-WidgetNoticeState
}

function Test-WidgetEditorOpen {
  # Any of the widget's own editing windows being open counts as "busy".
  return [bool]($script:audioDialogOpen -or ($script:quoteEditor -and $script:quoteEditor.IsVisible) -or ($script:characterGallery -and $script:characterGallery.IsVisible))
}


# --- quota pages ----------------------------------------------------------------
function Get-WidgetQuotaWindows {
  $order=@{'session'=0;'weekly'=1;'weekly-model'=2;'extra'=3}
  $windows=@($script:status.windows|Where-Object{$null-ne $_})
  return @($windows|Sort-Object @{Expression={$kind=[string]$_.kind;if($order.ContainsKey($kind)){$order[$kind]}else{9}}},@{Expression={[string]$_.model}})
}
function Get-WidgetQuotaPageCount {
  $count=@(Get-WidgetQuotaWindows).Count
  if($count-le 0){return 1}
  return [int][Math]::Ceiling($count/2)
}
function Get-WidgetQuotaPageWindows([int]$Page){
  $windows=@(Get-WidgetQuotaWindows)
  $start=$Page*2
  if($start-ge $windows.Count -or $start-lt 0){return @()}
  return @($windows[$start..([Math]::Min($start+1,$windows.Count-1))])
}
function Test-WidgetNeedsLogin {
  return [bool]($script:status -and ($script:status.errorCode-in @('NOT_LOGGED_IN','CHALLENGE')))
}
function Format-WidgetMoney($Minor,[string]$Currency){
  if($null-eq $Minor){return '—'}
  $code=if($Currency){$Currency.ToUpperInvariant()}else{'USD'}
  $symbol=switch($code){'USD'{'$'}'EUR'{'€'}'GBP'{'£'}'JPY'{'¥'}'CNY'{'¥'}default{$code+' '}}
  $digits=if($code-eq 'JPY'){0}else{2}
  $value=[double]$Minor/[Math]::Pow(10,$digits)
  return $symbol+$value.ToString('N'+$digits,[Globalization.CultureInfo]::InvariantCulture)
}
function Get-WidgetStaleSeconds {return 600}

function Get-WidgetCreditsDetailLine {
  $credits=$script:status.credits;$creditState=$script:status.creditsStatus
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$retryHint='请手动刷新'
  try{if([long]$creditState.retryAt-gt $now){$retryHint='请在 '+[DateTimeOffset]::FromUnixTimeMilliseconds([long]$creditState.retryAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)+' 后手动刷新'}}catch{}
  if(!$credits){
    if($creditState.state-eq 'error'){return '预付余额读取失败：'+$(if($creditState.error){[string]$creditState.error}else{'暂时无法读取'})+' · '+$retryHint}
    if($creditState.state-eq 'unavailable'){return '预付余额：尚未读取'}
    return $null
  }
  $at=$null
  try{if($credits.observedAt){$at=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$credits.observedAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)}}catch{}
  $previous=$creditState.state-in @('cached','error') -or $script:status.restored -or $script:status.queryOk-ne $true -or $creditState.queryOk-ne $true -or !$at -or $now-[long]$credits.observedAt-ge 1800000
  $line=$(if($previous){'上次预付余额：'}else{'预付余额：'})+(Format-WidgetMoney $credits.amountMinor $credits.currency)
  $line+='（'+$(if($at){$at+' 读取'}else{'读取时间未知'})+'）'
  if($creditState.state-eq 'error'){$line+=' · 余额刷新失败：'+$(if($creditState.error){[string]$creditState.error}else{'暂时无法读取'})+' · '+$retryHint}
  elseif($previous){$line+=' · 缓存'}
  return $line
}

# --- refresh, sign in, sign out ------------------------------------------------

function Start-WidgetBrowserHelper([ValidateSet('login','logout')][string]$Mode,[string]$OutFile){
  if($OutFile){Remove-Item -LiteralPath $OutFile -ErrorAction SilentlyContinue}
  $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $script:appDir 'runtime\claude-browser.ps1')+'"'),'-Mode',$Mode,'-ConfigPath',('"'+$script:configPath+'"'))
  if($OutFile){$arguments+=@('-OutFile',('"'+$OutFile+'"'))}
  return Start-Process -FilePath (Get-WidgetPowerShellPath) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}
function Test-WidgetBrowserOperationRunning($Process){
  if(!$Process){return $false}
  try{return !$Process.HasExited}catch{return $false}
}
function Start-WidgetLogin {
  if((Test-WidgetBrowserOperationRunning $script:loginProcess) -or (Test-WidgetBrowserOperationRunning $script:logoutProcess)){Show-WidgetNotice '登录或退出操作还在进行，请稍等。';return}
  try{
    $script:loginResultFile=Join-Path $script:dataDir ('login-result-'+[Guid]::NewGuid().ToString('N')+'.json')
    $script:loginProcess=Start-WidgetBrowserHelper 'login' $script:loginResultFile
    Show-WidgetNotice '登录窗口正在打开。登录后点角色或 ↻ 手动读取额度。'
  }catch{[Windows.MessageBox]::Show(('登录窗口没能打开：'+$_.Exception.Message),'Claude 娘')|Out-Null}
}
function Start-WidgetLogout {
  if((Test-WidgetBrowserOperationRunning $script:loginProcess) -or (Test-WidgetBrowserOperationRunning $script:logoutProcess)){Show-WidgetNotice '请先关闭登录窗口或等当前操作结束，再退出登录。';return}
  $answer=[Windows.MessageBox]::Show($script:window,'退出后 Claude 娘就读不到额度了（不影响 Claude 桌面端本身的登录）。确定退出吗？','Claude 娘 · 退出登录',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question)
  if($answer-ne [Windows.MessageBoxResult]::Yes){return}
  try{
    $script:logoutResultFile=Join-Path $script:dataDir ('logout-result-'+[Guid]::NewGuid().ToString('N')+'.json')
    $script:logoutProcess=Start-WidgetBrowserHelper 'logout' $script:logoutResultFile
  }catch{[Windows.MessageBox]::Show(('退出登录失败：'+$_.Exception.Message),'Claude 娘')|Out-Null}
}
function Write-WidgetSessionReset([ValidateSet('signed-in','signed-out')][string]$State){
  Write-WidgetJson -NoBackup (Join-Path $script:dataDir 'session-reset.flag') @{id=[Guid]::NewGuid().ToString('N');at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();state=$State}
  $script:noticeState=@{notified=@{};last=@{}};$script:noticeQueue=@();$script:noticeLastStamp='';Save-WidgetNoticeState
  $script:status=[pscustomobject]@{ok=$false;queryOk=$false;windows=@();loggedIn=($State-eq 'signed-in');errorCode=$(if($State-eq 'signed-out'){'NOT_LOGGED_IN'}else{'MANUAL'});error=$(if($State-eq 'signed-out'){'已退出登录，请先登录 Claude 账号'}else{'登录成功，点角色或 ↻ 手动读取额度'})}
  $script:statusStamp=[IO.File]::GetLastWriteTimeUtc((Join-Path $script:dataDir 'status.json')).Ticks
}
function Tick-WidgetBrowserHelpers {
  foreach($mode in @('login','logout')){
    $process=if($mode-eq 'login'){$script:loginProcess}else{$script:logoutProcess}
    if(!$process -or (Test-WidgetBrowserOperationRunning $process)){continue}
    $out=if($mode-eq 'login'){$script:loginResultFile}else{$script:logoutResultFile}
    $result=$null;try{$result=Read-WidgetJsonFile $out}catch{}
    try{$process.Dispose()}catch{}
    if($mode-eq 'login'){$script:loginProcess=$null}else{$script:logoutProcess=$null}
    if($out){Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue}
    if($mode-eq 'logout'){
      if($result -and $result.ok-eq $true -and $result.signedOut-eq $true){Write-WidgetSessionReset 'signed-out';Show-WidgetNotice '已退出登录。想看额度时右键我 → 登录 Claude 账号。'}
      else{
        $reason=if($result.errorCode-eq 'BROWSER_BUSY'){'内置浏览器正忙，请关闭登录窗口或等查询结束后再试'}elseif($result.error){[string]$result.error}else{'没有收到退出成功结果，请重试'}
        Show-WidgetNotice ('退出登录失败：'+$reason)
      }
    }elseif($result -and $result.ok-eq $true -and $result.signedIn-eq $true){Write-WidgetSessionReset 'signed-in';Show-WidgetNotice '登录成功！点角色或 ↻ 手动查看额度。'}
    elseif($result.errorCode-eq 'BROWSER_BUSY'){Show-WidgetNotice '内置浏览器正忙，请关闭已有登录窗口或等查询结束后再试。'}
    elseif($result.errorCode-eq 'NO_WEBVIEW2'){Show-WidgetNotice '缺少 Microsoft Edge WebView2 运行时，请安装后再登录。'}
    elseif($result.error){Show-WidgetNotice ('登录没有完成：'+[string]$result.error)}
  }
}
function Set-WidgetPreferredOrg([string]$Uuid){
  if($Uuid-notmatch '^[0-9a-fA-F-]{8,64}$'){return}
  if($script:preferredOrg-ieq $Uuid -and $script:status.selectedOrg-ieq $Uuid){return}
  $script:preferredOrg=$Uuid.ToLowerInvariant();$script:quotaPage=0;$script:noticeQueue=@();Save-Settings
  $orgs=@($script:status.orgs);$org=@($orgs|Where-Object{$_.uuid-ieq $Uuid})[0]
  $script:status=[pscustomobject]@{ok=$false;queryOk=$false;windows=@();selectedOrg=$script:preferredOrg;orgs=$orgs;errorCode='SWITCHING_ORG';error='正在读取所选组织的额度…';planLabel=$org.planLabel;org=@{name=$org.name;count=$orgs.Count}}
  $script:statusStamp=[IO.File]::GetLastWriteTimeUtc((Join-Path $script:dataDir 'status.json')).Ticks
  Request-Refresh
}

function Protect-WidgetSelectedOrganization {
  if(!$script:preferredOrg -or !$script:status -or !$script:status.selectedOrg -or $script:status.selectedOrg-ieq $script:preferredOrg){return}
  $orgs=@($script:status.orgs);$org=@($orgs|Where-Object{$_.uuid-ieq $script:preferredOrg})[0]
  $script:status=[pscustomobject]@{ok=$false;queryOk=$false;windows=@();orgs=$orgs;selectedOrg=$script:preferredOrg;planLabel=$org.planLabel;org=@{name=$org.name;count=$orgs.Count};errorCode='SWITCHING_ORG';error='组织已切换，正在等待所选组织的读取结果'}
}

# --- notices (low quota, reset, sign-in) ---------------------------------------
function Read-WidgetNoticeState {
  $state=@{notified=@{};last=@{}}
  try{
    $saved=Get-Content -LiteralPath (Join-Path $script:dataDir 'notices.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($saved.version-ne 2){return $state}
    foreach($key in @($saved.notified)){if($key-is [string] -and $key-match '^(low|reset)\|[a-f0-9]{64}\|' -and $key.Length-lt 300){$state.notified[$key]=0L}}
    foreach($row in @($saved.last)){if($row.key-is [string] -and $row.key-match '^[a-f0-9]{64}\|'){$state.last[$row.key]=@{used=[double]$row.used;resetsAt=[long]$row.resetsAt;at=[long]$row.at}}}
  }catch{}
  return $state
}
function Save-WidgetNoticeState {
  try{
    $keys=@($script:noticeState.notified.Keys|Sort-Object {$script:noticeState.notified[$_]} -Descending|Select-Object -First 200)
    $last=@(foreach($key in @($script:noticeState.last.Keys|Sort-Object {$script:noticeState.last[$_].at} -Descending|Select-Object -First 200)){@{key=$key;used=$script:noticeState.last[$key].used;resetsAt=$script:noticeState.last[$key].resetsAt;at=$script:noticeState.last[$key].at}})
    Write-WidgetJson (Join-Path $script:dataDir 'notices.json') @{version=2;notified=$keys;last=$last}
  }catch{Write-WidgetLog $script:dataDir 'widget' ('提醒记录保存失败：'+$_.Exception.Message)}
}
function Test-WidgetNoticeBusy {
  return [bool]$script:drag -or $script:context.IsOpen -or $script:settingsSizePreview -or (Test-WidgetEditorOpen)
}
function Show-WidgetNotice([string]$Text){
  if(!$Text){return}
  if(!$script:window.IsVisible -or (Test-WidgetNoticeBusy)){$script:pendingNotice=@{text=$Text;at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()};return}
  $script:pendingNotice=$null;$script:nextQuoteOverride=$Text
  if($script:collapsed){Open-WidgetBubble 'quote'}else{Switch-Scene 'quote'}
}
function Tick-WidgetClaudeNotices([bool]$Visible){
  Tick-WidgetBrowserHelpers
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if($script:pendingNotice){
    if($now-[long]$script:pendingNotice.at-gt 600000){$script:pendingNotice=$null}
    elseif($Visible -and $script:collapsed -and !(Test-WidgetNoticeBusy)){Show-WidgetNotice $script:pendingNotice.text}
  }
  $script:noticeQueue=@($script:noticeQueue|Where-Object{$now-[long]$_.at-lt 600000 -and $_.accountKey-eq $script:status.accountKey})
  if($script:noticeQueue.Count -and $Visible -and $script:window.IsVisible -and $script:collapsed -and !(Test-WidgetNoticeBusy)){
    $item=$script:noticeQueue[0]
    Show-WidgetNotice $item.text
    foreach($key in @($item.keys)){$script:noticeState.notified[$key]=$now}
    $script:noticeQueue=@($script:noticeQueue|Select-Object -Skip 1);Save-WidgetNoticeState
  }
  if(!$script:status -or !$script:status.ok -or $script:status.queryOk-ne $true -or $script:status.restored -or !$script:status.observedAt -or !$script:status.accountKey){return}
  if($now-[long]$script:status.observedAt-lt 0 -or $now-[long]$script:status.observedAt-gt 600000){return}
  $stamp=[string]$script:status.accountKey+':'+[string]$script:status.observedAt
  if($stamp-eq $script:noticeLastStamp){return}
  $script:noticeLastStamp=$stamp
  if(!$script:noticeState){$script:noticeState=Read-WidgetNoticeState}
  $messages=@();$keys=@();$queued=@($script:noticeQueue|ForEach-Object{$_.keys})
  foreach($window in @($script:status.windows)){
    if(!$window -or $window.kind-notin @('session','weekly','weekly-model') -or $null-eq $window.used -or $null-eq $window.remaining){continue}
    $resets=if($window.resetsAt){[long]$window.resetsAt}else{0L}
    if($resets-gt 0 -and $resets*1000-le $now){continue}
    $windowKey=if($window.key){[string]$window.key}else{[string]$window.kind+':'+[string]$window.model}
    $key=[string]$script:status.accountKey+'|'+$windowKey
    $used=[double]$window.used;$remaining=[double]$window.remaining;$label=[string]$window.label
    $previous=$script:noticeState.last[$key]
    $resetKey='reset|'+$key+'|'+$resets
    if($script:resetAlert -and $previous -and $previous.used-ge 50 -and $used-le 10 -and $resets-ne [long]$previous.resetsAt -and !$script:noticeState.notified.ContainsKey($resetKey) -and $resetKey-notin $queued){$messages+=($label+' 额度重置啦，满血复活～');$keys+=$resetKey}
    $threshold=if($window.kind-eq 'session'){20}else{15};$lowKey='low|'+$key+'|'+$resets
    if($script:lowQuotaAlert -and $remaining-le $threshold -and !$script:noticeState.notified.ContainsKey($lowKey) -and $lowKey-notin $queued){$messages+=($label+' 额度只剩 '+$remaining.ToString('0.#')+'% 了，省着点用～');$keys+=$lowKey}
    $script:noticeState.last[$key]=@{used=$used;resetsAt=$resets;at=$now}
  }
  if($messages.Count){$script:noticeQueue+=,@{text=($messages-join '；');keys=$keys;accountKey=$script:status.accountKey;at=$now}}
  Save-WidgetNoticeState
}

# --- tooltip details ------------------------------------------------------------
function Get-WidgetWeeklyPaceText($Window,[long]$NowSeconds){
  if(!$Window -or !$Window.resetsAt -or $null-eq $Window.used){return $null}
  $left=[double]$Window.resetsAt-$NowSeconds
  if($left-le 0 -or $left-gt 7*86400){return $null}
  $elapsed=1-$left/(7*86400)
  $days=(7*$elapsed).ToString('0.0')
  $pace=if([double]$Window.used-gt $elapsed*100+10){'，比时间进度快，留意一下'}elseif([double]$Window.used-lt $elapsed*100-10){'，很宽裕'}else{''}
  return '本周已过 '+$days+' 天（'+[Math]::Round($elapsed*100)+'%），每周额度已用 '+([double]$Window.used).ToString('0.#')+'%'+$pace
}
function Get-WidgetClaudeDetailLines([long]$NowSeconds){
  $lines=@()
  if(!$script:status){return $lines}
  if($script:status.org -and $script:status.org.name){
    $lines+=('组织：'+$script:status.org.name+$(if([int]$script:status.org.count-gt 1){'（共 '+$script:status.org.count+' 个，可在设置里切换）'}else{''}))
  }
  foreach($window in @(Get-WidgetQuotaWindows)){
    if($window.kind-eq 'extra'){
      $line='额外用量：已用 '+(Format-WidgetMoney $window.usedMinor $window.currency)
      if($null-ne $window.limitMinor){$line+=' / 每月上限 '+(Format-WidgetMoney $window.limitMinor $window.currency)}
      $lines+=$line;continue
    }
    $detail=if($window.resetsAt -and [long]$window.resetsAt-gt 0){Format-ResetTime ([long]$window.resetsAt) $NowSeconds}else{'未提供重置时间'}
    $expired=$window.resetsAt -and [long]$window.resetsAt-gt 0 -and [long]$window.resetsAt-le $NowSeconds
    $lines+=([string]$window.label+$(if($expired){'：上次剩余 '}else{'：剩余 '})+([double]$window.remaining).ToString('0.#')+'%，'+$detail)
  }
  $creditLine=Get-WidgetCreditsDetailLine
  if($creditLine){$lines+=$creditLine}
  $weekly=@(Get-WidgetQuotaWindows|Where-Object{$_.kind-eq 'weekly'})[0]
  $pace=Get-WidgetWeeklyPaceText $weekly $NowSeconds
  if($pace){$lines+=$pace}
  if($script:status.today -and $script:status.today.accountKey-eq $script:status.accountKey -and $script:status.today.day-eq [DateTime]::Now.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) -and $null-ne $script:status.today.weeklyUsed){
    $since=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$script:status.today.since).ToLocalTime().ToString('HH:mm')
    $lines+=('今日观测到的周额度增量约 +'+([double]$script:status.today.weeklyUsed).ToString('0.#')+'%（'+$since+' 起统计）')
  }

  return $lines
}

# --- settings menu ------------------------------------------------------------
$script:orgMenuKey=$null
function Update-WidgetClaudeMenu {
  if(!$script:settingsMenuUi -or !$script:settingsMenuUi.AccountState){return}
  $status=$script:status
  $text=if(!$status){'正在读取…'}
    elseif(Test-WidgetNeedsLogin){'未登录：登录后才能读取额度'}
    elseif($status.planLabel -and $status.ok){'已登录 · '+$status.planLabel+$(if($status.org -and $status.org.name){' · '+$status.org.name}else{''})}
    elseif($status.error){[string]$status.error}else{'正在读取…'}
  $script:settingsMenuUi.AccountState.Header.Text=$text
  $orgs=@($status.orgs|Where-Object{$_ -and $_.uuid})
  # A just-picked organization stays ticked while its first read is running.
  $checkedOrg=if($script:preferredOrg -and @($orgs|Where-Object{[string]$_.uuid-eq $script:preferredOrg}).Count){$script:preferredOrg}else{[string]$status.selectedOrg}
  $key=(@($orgs|ForEach-Object{[string]$_.uuid+'|'+[string]$_.name+'|'+[string]$_.planLabel})-join ';')+'#'+$checkedOrg
  if($key-ne $script:orgMenuKey){
    $script:orgMenuKey=$key
    $menu=$script:settingsMenuUi.Orgs
    $menu.Items.Clear()
    if($orgs.Count-eq 0){
      $empty=New-Object Windows.Controls.MenuItem;$empty.Style=$script:settingsMenuResources['SettingsItem'];$empty.Header='（登录后显示）';$empty.IsEnabled=$false
      $menu.Items.Add($empty)|Out-Null
    }else{
      foreach($org in $orgs){
        $item=New-Object Windows.Controls.MenuItem;$item.Style=$script:settingsMenuResources['SettingsItem']
        $item.Header=[string]$org.name+$(if($org.planLabel){' · '+[string]$org.planLabel}else{''})
        $item.IsCheckable=$true;$item.Uid='radio';$item.Tag=[string]$org.uuid;$item.StaysOpenOnClick=$true
        $item.IsChecked=[string]$org.uuid-eq $checkedOrg
        # Only re-tick here: rebuilding the open submenu inside its own click is avoided.
        $item.Add_Click({param($sender,$clickArgs)
          Set-WidgetPreferredOrg ([string]$sender.Tag)
          foreach($other in @($script:settingsMenuUi.Orgs.Items)){if($other-is [Windows.Controls.MenuItem]){$other.IsChecked=[string]$other.Tag-eq [string]$sender.Tag}}
        })
        $menu.Items.Add($item)|Out-Null
      }
    }
  }
  $script:settingsMenuUi.LowQuota.IsChecked=$script:lowQuotaAlert
  $script:settingsMenuUi.ResetAlert.IsChecked=$script:resetAlert
}
