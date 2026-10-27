# Renders status.json into the bubble: the two quota rows of the current
# page, reset times, the status line and the header.
function Reset-Label($seconds){
  if($seconds-le 0){return '重置已到 · 等待刷新'}
  $minutes=[Math]::Ceiling($seconds/60)
  if($minutes-lt 60){return "$minutes 分钟后重置"}
  if($minutes-lt 1440){$h=[Math]::Floor($minutes/60);$m=$minutes%60;if($m-eq 0){return "$h 小时后重置"};return "$h 小时 $m 分后重置"}
  $d=[Math]::Floor($minutes/1440);$h=[Math]::Floor(($minutes%1440)/60);if($h-eq 0){return "$d 天后重置"};return "$d 天 $h 小时后重置"
}
function Format-ResetTime([long]$timestamp,[long]$now,[TimeZoneInfo]$timeZone=[TimeZoneInfo]::Local){
  if($timestamp-le $now){return '重置已到，等待更新'}
  $reset=[TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeSeconds($timestamp),$timeZone)
  $today=[TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeSeconds($now),$timeZone).Date
  $day=if($reset.Date-eq $today){'今日'}elseif($reset.Date-eq $today.AddDays(1)){'明日'}else{$reset.ToString('MM-dd')}
  return $day+' '+$reset.ToString('HH:mm')+' 重置'
}
function Format-ResetDisplay([long]$timestamp,[long]$now){
  if($timestamp-le $now -or $script:resetTimeMode-eq 'fixed'){return Format-ResetTime $timestamp $now}
  return Reset-Label ($timestamp-$now)
}
function Get-QuotaWindowLabel($Window,[string]$Fallback){
  if(!$Window){return $Fallback}
  $label=[string]$Window.label
  if(!$label){
    $minutes=[long]$Window.minutes
    $label=if($minutes-eq 300){'5 小时'}elseif($minutes-eq 10080){'每周'}elseif($minutes-gt 0 -and $minutes%1440-eq 0){([string]($minutes/1440))+' 天'}elseif($minutes-gt 0 -and $minutes%60-eq 0){([string]($minutes/60))+' 小时'}elseif($minutes-gt 0){([string]$minutes)+' 分钟'}else{'额度'}
  }
  return $label
}
function Get-QuotaRows {
  # Two visual rows per page: 5 小时 + 每周 first, then per-model weekly
  # windows and extra usage on the following pages.
  $pageCount=Get-WidgetQuotaPageCount
  if($script:quotaPage-ge $pageCount -or $script:quotaPage-lt 0){$script:quotaPage=0}
  $windows=@(Get-WidgetQuotaPageWindows $script:quotaPage)
  $first=if($windows.Count-ge 1){$windows[0]}else{$null}
  $second=if($windows.Count-ge 2){$windows[1]}else{$null}
  @(@{prefix='Short';window=$first;label=(Get-QuotaWindowLabel $first '5 小时')},@{prefix='Week';window=$second;label=(Get-QuotaWindowLabel $second '每周')})
}
function Set-ResetTimeMode([string]$mode,[long]$nowMilliseconds){
  $script:resetTimeMode=$mode
  $now=[long][Math]::Floor($nowMilliseconds/1000)
  foreach($row in (Get-QuotaRows)){
    $q=$row.window
    if($q -and $null-ne $q.resetsAt -and [double]$q.resetsAt-gt 0){$script:ui[$row.prefix+'Reset'].Text=Format-ResetDisplay ([long]$q.resetsAt) $now}
  }
}
function Update-Quota {
  $file=Join-Path $script:dataDir 'status.json'
  try{$stamp=[IO.File]::GetLastWriteTimeUtc($file).Ticks
    if(!(Test-Path -LiteralPath $file)){$script:status=$null;$script:statusStamp=0}
    elseif($stamp-ne $script:statusStamp){$script:status=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json;$script:statusStamp=$stamp}
  }catch{$script:status=$null;$script:statusStamp=0}
  Protect-WidgetSelectedOrganization
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  # What is drawn below changes only with the status, the page or scene, the
  # minutes left before each reset (countdowns, a window reaching its reset) and
  # the passing minute (staleness, today/tomorrow). A once-a-second tick with
  # none of these changed skips the redraw, which used to cost about 4 ms.
  $minutesLeft=@(foreach($window in @($script:status.windows)){if($window -and $window.resetsAt){[Math]::Ceiling(([double]$window.resetsAt-$now)/60)}})-join ','
  $renderKey=@($script:statusStamp,[Math]::Floor($now/60),$minutesLeft,$script:quotaPage,$script:resetTimeMode,$script:collapsed,$script:bubbleMode)-join '|'
  if($renderKey-eq $script:quotaRenderKey -and [object]::ReferenceEquals($script:status,$script:quotaRenderStatus)){return}
  $script:quotaRenderKey=$renderKey;$script:quotaRenderStatus=$script:status
  $converter=[Windows.Media.BrushConverter]::new()
  $hasWindows=@(Get-WidgetQuotaWindows).Count-gt 0
  $needsLogin=Test-WidgetNeedsLogin
  foreach($row in (Get-QuotaRows)){
    $prefix=$row.prefix;$q=$row.window
    $script:ui[$prefix+'Label'].Text=$row.label
    $script:ui[$prefix+'Label'].Foreground=$converter.ConvertFromString('#8A6352')
    $noWindows=$script:status -and $script:status.errorCode-eq 'NO_WINDOWS'
    $collapse=!$q -and ($hasWindows -or $script:status.queryOk-eq $true)
    # A plan without quota windows (Free) still shows one explanatory row.
    if(!$q -and !$hasWindows -and $noWindows -and $prefix-eq 'Short'){$collapse=$false}
    $script:ui[$prefix+'Row'].Visibility=if($collapse){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}
    $script:ui[$prefix+'Reset'].ToolTip=$null
    $tone=Get-WidgetQuotaTone $q $now
    if(!$q){
      $script:ui[$prefix+'Used'].Text='已用 —';$script:ui[$prefix+'Left'].Text='—'
      $script:ui[$prefix+'Reset'].Text=if($needsLogin){if($prefix-eq 'Short'){'点气泡登录 Claude 账号'}else{'登录后显示额度'}}
        elseif(!$script:status -or (!$script:status.ok -and !$script:status.errorCode)){'点角色读取额度'}
        elseif($script:status.errorCode-eq 'MANUAL'){'点角色或 ↻ 手动读取'}
        elseif($script:status.errorCode-eq 'SWITCHING_ORG'){'正在切换组织…'}
        elseif($noWindows){'这个套餐没有额度窗口'}
        elseif($script:status.queryOk-ne $true){'额度读取异常'}
        else{'暂无额度数据'}
      $script:ui[$prefix+'Bar'].Width=0;$script:ui[$prefix+'Left'].Foreground=$converter.ConvertFromString($script:claudeInk.muted);continue
    }
    if($q.kind-eq 'extra'){
      # 额外用量：百分比表示本月上限还剩多少；金额在下方一行。
      $hasShare=$null-ne $q.remaining
      $script:ui[$prefix+'Used'].Text=if($hasShare){'已用 '+([double]$q.used).ToString('0.#')+'%'}else{'已用 '+(Format-WidgetMoney $q.usedMinor $q.currency)}
      $script:ui[$prefix+'Left'].Text=if($hasShare){([double]$q.remaining).ToString('0.#')+'%'}else{Format-WidgetMoney $q.usedMinor $q.currency}
      $script:ui[$prefix+'Reset'].Text='已用 '+(Format-WidgetMoney $q.usedMinor $q.currency)+$(if($null-ne $q.limitMinor){' / '+(Format-WidgetMoney $q.limitMinor $q.currency)}else{''})
      if($script:status.credits){$script:ui[$prefix+'Reset'].ToolTip='预付余额 '+(Format-WidgetMoney $script:status.credits.amountMinor $script:status.credits.currency)}
      $script:ui[$prefix+'Bar'].Width=if($hasShare){184*[double]$q.remaining/100}else{0}
    }else{
      $hasReset=$null-ne $q.resetsAt -and [double]$q.resetsAt-gt 0
      $expired=$hasReset -and [double]$q.resetsAt-le $now
      $used=([double]$q.used).ToString('0.#');$left=([double]$q.remaining).ToString('0.#')
      $script:ui[$prefix+'Used'].Text=if($expired){"上次 $used%"}else{"已用 $used%"}
      $script:ui[$prefix+'Left'].Text=if($expired){'—'}else{"$left%"}
      $script:ui[$prefix+'Reset'].Text=if($hasReset){Format-ResetDisplay ([long]$q.resetsAt) $now}else{'未提供重置时间'}
      if($hasReset){$script:ui[$prefix+'Reset'].ToolTip='本机时间 '+[DateTimeOffset]::FromUnixTimeSeconds([long]$q.resetsAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm zzz',[Globalization.CultureInfo]::InvariantCulture)+' 重置 · '+(Reset-Label ([double]$q.resetsAt-$now))}
      $script:ui[$prefix+'Bar'].Width=if($expired){0}else{184*[double]$q.remaining/100}
    }
    $script:ui[$prefix+'Bar'].Background=$converter.ConvertFromString($script:claudeBar[$tone])
    $script:ui[$prefix+'Left'].Foreground=$converter.ConvertFromString($script:claudeInk[$tone])
  }
  $script:ui.WeekRow.Margin=if($script:ui.ShortRow.Visibility-eq [Windows.Visibility]::Collapsed){[Windows.Thickness]::new(0,1,0,0)}else{[Windows.Thickness]::new(0,4,0,0)}
  $age=if($script:status.observedAt){$now-[Math]::Floor([double]$script:status.observedAt/1000)}else{0}
  $stale=Get-WidgetStaleSeconds
  $dot='#D9825F'
  if(!$script:status){$script:ui.Status.Text='正在读取 Claude 额度…';$dot='#D9A441'}
  elseif(!$script:status.ok){$script:ui.Status.Text=[string]$script:status.error;$dot='#D9A441'}
  else{
    $at=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$script:status.observedAt).ToLocalTime().ToString('HH:mm:ss')
    if($script:status.restored){$script:ui.Status.Text="上次读取于 $at · 点 ↻ 手动刷新";$dot='#D9A441'}
    elseif($script:status.error){$script:ui.Status.Text="刷新未成功：$($script:status.error) · 上次 $at";$dot='#D9A441'}
    elseif($age-gt $stale){$mins=[Math]::Floor($age/60);$script:ui.Status.Text="$mins 分钟前的额度 · 点击 ↻ 刷新";$dot='#D9A441'}
    else{$script:ui.Status.Text="$at 更新 · 仅手动刷新"}
  }
  $script:ui.LiveDot.Fill=$converter.ConvertFromString($dot)
  $script:ui.Status.ToolTip=$script:ui.Status.Text
  $pages=Get-WidgetQuotaPageCount
  $headerState=if(!$script:status){'正在读取'}elseif($needsLogin -and !$script:status.ok){'未登录'}elseif($script:status.errorCode-eq 'NO_WINDOWS'){'无额度窗口'}elseif($script:status.errorCode-eq 'MANUAL'){'点击读取'}elseif($script:status.errorCode-eq 'SWITCHING_ORG'){'切换组织中'}elseif(!$script:status.ok){'暂无法读取'}elseif($script:status.error -or $script:status.restored -or $age-gt $stale){'上次额度'}elseif($script:quotaPage-gt 0){'其他额度 '+($script:quotaPage+1)+'/'+$pages}else{'剩余额度'}
  $planTitle=([string]$script:status.planLabel).Trim()
  $script:ui.Header.Text=if($planTitle -and $planTitle-ne '未知套餐' -and ($script:status.ok -or $script:status.errorCode-eq 'NO_WINDOWS')){$planTitle+' · '+$headerState}else{$headerState}
  $script:ui.Header.ToolTip=if($script:status.planLabel){'当前套餐：'+$script:status.planLabel+' · 重置时间按本机时间显示'}else{'重置时间按本机时间显示'}
  Update-BubbleTooltip
}
