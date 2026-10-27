# The speech bubble: open and close animations, the quota and quote scenes
# with their timers, and what a click on the character or the bubble does.
function Set-AnimatedValue($target,$property,[double]$value) {
  $target.BeginAnimation($property,$null);$target.SetValue($property,$value)
}
function Animate-Value($target,$property,[double]$to,[int]$duration,[int]$delay=0,[bool]$rebound=$false) {
  $from=[double]$target.GetValue($property)
  $target.BeginAnimation($property,$null);$target.SetValue($property,$from)
  $animation=New-Object Windows.Media.Animation.DoubleAnimation
  $animation.From=$from;$animation.To=$to
  $animation.Duration=[Windows.Duration]::new([TimeSpan]::FromMilliseconds($duration))
  $animation.BeginTime=[TimeSpan]::FromMilliseconds($delay)
  $ease=New-Object ClaudeBezierEase
  if($rebound){$ease.X1=0.34;$ease.Y1=1.56;$ease.X2=0.64;$ease.Y2=1}
  $ease.EasingMode=[Windows.Media.Animation.EasingMode]::EaseIn;$animation.EasingFunction=$ease
  $target.BeginAnimation($property,$animation)
}
function Set-BubbleState {
  foreach($name in @('Bubble','Tail','TailNear')){
    $element=$script:ui[$name]
    $element.Visibility=if($script:collapsed -and !$script:settingsBubblePreview){[Windows.Visibility]::Hidden}else{[Windows.Visibility]::Visible}
    Set-AnimatedValue $element ([Windows.UIElement]::OpacityProperty) 1
    Set-AnimatedValue $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 1
    Set-AnimatedValue $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 1
  }
  Set-AnimatedValue $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 1
  $script:ui.Bubble.IsHitTestVisible=!$script:collapsed
}
$script:bubbleEpoch=0;$script:closeTimer=$null
function Restart-SceneTtl([int]$renderDelay=0,[long]$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()){
  $script:sceneStartedAt=$now+$renderDelay;$script:sceneDeadline=$script:sceneStartedAt+5000
  Set-ResetTimeMode 'countdown' $now
  if($script:resetPhaseTimer){$script:resetPhaseTimer.Stop();$script:resetPhaseTimer=$null}
  if(!$script:collapsed -and $script:bubbleMode-eq 'quota'){
    $script:resetPhaseTimer=New-Object Windows.Threading.DispatcherTimer
    $script:resetPhaseTimer.Interval=[TimeSpan]::FromMilliseconds($renderDelay+2000)
    $script:resetPhaseTimer.Add_Tick({param($timer,$event)
      try{
        if($timer-ne $script:resetPhaseTimer){$timer.Stop();return}
        $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Tick-Scene $now
        if($script:collapsed -or $script:bubbleMode-ne 'quota'){$timer.Stop()}
        else{
          $next=if($script:resetTimeMode-eq 'fixed'){$script:sceneDeadline}else{$script:sceneStartedAt+2000}
          $timer.Interval=[TimeSpan]::FromMilliseconds([Math]::Max(1,$next-$now))
        }
      }catch{
        # A transient settings-write failure must not become an unhandled
        # dispatcher exception; stop this one-shot timer and keep the widget alive.
        $timer.Stop()
        Write-WidgetLog $script:dataDir 'widget' $_
      }
    })
    $script:resetPhaseTimer.Start()
  }
}
function Tick-Scene([long]$now){
  if($script:settingsSizePreview){return}
  if($script:collapsed -or $script:sceneDeadline-le 0){return}
  if($now-ge $script:sceneDeadline){Hide-Quota;return}
  if($script:bubbleMode-eq 'quota' -and $script:resetTimeMode-ne 'fixed' -and $now-ge $script:sceneStartedAt+2000){Set-ResetTimeMode 'fixed' $now}
}
function Read-DisplayRequest {
  try{
    $request=Get-Content -LiteralPath (Join-Path $script:dataDir 'display-request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($request.nonce -and $request.nonce-ne $script:displayRequestToken){
      Reset-WidgetAutoQuoteSchedule
      $script:displayRequestToken=$request.nonce
      if([Math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-[long]$request.at)-lt 10000){
        if($request.mode-eq 'quota'){Show-Quota}
        elseif($request.mode-eq 'quote'){Show-Quote}
        elseif($request.mode-eq 'menu' -and $script:window.IsVisible){Open-WidgetMenu}
        elseif($request.mode-eq 'characters' -and $script:window.IsVisible){Open-WidgetCharacterGallery}
        elseif($request.mode-eq 'close-menu'){$script:context.IsOpen=$false}
        elseif($request.mode-eq 'music-on'){Set-WidgetMusicEnabled $true}
        elseif($request.mode-eq 'music-off'){Set-WidgetMusicEnabled $false}
      }
    }
  }catch{}
}
function Apply-Scene {
  if($script:bubbleMode-eq 'quota'){Update-Quota}
  Set-WidgetSceneLayout
  $quota=$script:bubbleMode-eq 'quota'
  $script:ui.QuotaText.Visibility=if($quota){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
  $script:ui.QuoteText.Visibility=if($quota){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}
  $script:ui.Refresh.Visibility=$script:ui.QuotaText.Visibility;$script:ui.LiveDot.Visibility=[Windows.Visibility]::Collapsed
  Update-BubbleTooltip
}
function Update-BubbleTooltip {
  $copy=if($script:bubbleMode-eq 'quote'){$script:ui.QuoteText.Tag}else{
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $parts=@()
    if($script:status.planLabel){$parts+='当前套餐：'+$script:status.planLabel}
    $parts+=@(Get-WidgetClaudeDetailLines $now)
    $pages=Get-WidgetQuotaPageCount
    if($pages-gt 1){$parts+=('点气泡翻页（共 '+$pages+' 页），翻完再点看语录')}
    if(Test-WidgetNeedsLogin){$parts+='点气泡打开登录窗口'}
    ($parts+@($script:ui.Status.Text))-join "`n"
  }
  if(!$script:bubbleTooltipText){
    $script:bubbleTooltipText=New-Object Windows.Controls.TextBlock
    $script:bubbleTooltipText.TextWrapping=[Windows.TextWrapping]::Wrap
    $script:bubbleTooltipText.MaxWidth=340;$script:bubbleTooltipText.FontSize=15;$script:bubbleTooltipText.LineHeight=23
    $script:ui.Bubble.ToolTip=$script:bubbleTooltipText
    [Windows.Controls.ToolTipService]::SetShowDuration($script:ui.Bubble,20000)
  }
  $script:bubbleTooltipText.Text=[string]$copy
}

function Get-WidgetBubbleQuote([string]$DataDir){
  # A pending notice (低额度/重置/登录提醒) is shown once instead of a quote.
  if($script:nextQuoteOverride){$text=[string]$script:nextQuoteOverride;$script:nextQuoteOverride=$null;return $text}
  return Get-WidgetQuote $DataDir
}
function Switch-Scene([string]$mode){
  if($script:collapsed){return}
  Reset-WidgetAutoQuoteSchedule
  $script:sceneRevision++;$script:bubbleMode=$mode
  if($mode-eq 'quote'){$script:ui.QuoteText.Text=Get-WidgetBubbleQuote $script:dataDir;Fit-QuoteText}
  if($script:sceneTimer){$script:sceneTimer.Stop()}
  Animate-Value $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 0 120
  $script:sceneTimer=New-Object Windows.Threading.DispatcherTimer
  $script:sceneTimer.Interval=[TimeSpan]::FromMilliseconds(120)
  $script:sceneTimer.Add_Tick({param($timer,$event)
    $timer.Stop()
    try{
      if($timer-eq $script:sceneTimer -and !$script:collapsed){
        Apply-Scene;Animate-Value $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 1 160
        Restart-SceneTtl 160
      }
    }catch{
      Write-WidgetLog $script:dataDir 'widget' $_
    }
  })
  $script:sceneTimer.Start();Restart-SceneTtl 280
}
function Next-Bubble {
  if($script:collapsed){return}
  if($script:bubbleMode-eq 'quota'){
    if(Test-WidgetNeedsLogin){Hide-Quota;Start-WidgetLogin;return}
    if($script:quotaPage+1-lt (Get-WidgetQuotaPageCount)){$script:quotaPage++;Switch-Scene 'quota';return}
    Switch-Scene 'quote'
  }else{Hide-Quota}
}
function Click-Character {
  if($script:collapsed){Show-Quota}
  elseif($script:bubbleTapAdvance){Next-Bubble}
  elseif($script:bubbleMode-ne 'quota'){$script:quotaPage=0;Switch-Scene 'quota'}
  else{Restart-SceneTtl}
}
function Tick-WidgetAutoQuote([long]$Now,[bool]$Visible) {
  $busy=!$script:collapsed -or [bool]$script:drag -or $script:context.IsOpen -or $script:settingsSizePreview -or ($script:closeTimer -and $script:closeTimer.IsEnabled) -or (Test-WidgetEditorOpen)
  if(Test-WidgetAutoQuoteDue $Now $Visible ([bool]$busy)){Show-Quote;$script:autoQuoteDisplayCount++}
}
function Show-Quota {
  $wasCollapsed=$script:collapsed
  if($wasCollapsed){$script:quotaPage=0}
  Open-WidgetBubble 'quota'
  if($wasCollapsed){Request-Refresh}
}
function Show-Quote {Open-WidgetBubble 'quote'}
function Open-WidgetBubble([ValidateSet('quota','quote')][string]$Mode) {
  Reset-WidgetAutoQuoteSchedule
  if(!$script:collapsed){if($Mode-eq 'quote' -or $script:bubbleMode-ne $Mode){Switch-Scene $Mode}else{Restart-SceneTtl};return}
  $script:bubbleEpoch++;$script:collapsed=$false;$script:sceneRevision++
  $script:bubbleMode=$Mode
  if($Mode-eq 'quote'){$script:ui.QuoteText.Text=Get-WidgetBubbleQuote $script:dataDir;Fit-QuoteText}
  Apply-Scene
  if($script:sceneTimer){$script:sceneTimer.Stop()}
  if($script:closeTimer){$script:closeTimer.Stop();$script:closeTimer=$null}
  foreach($stage in @(@{name='TailNear';delay=0},@{name='Tail';delay=130},@{name='Bubble';delay=260})){
    $element=$script:ui[$stage.name];$element.Visibility=[Windows.Visibility]::Visible
    Set-AnimatedValue $element ([Windows.UIElement]::OpacityProperty) 0
    Set-AnimatedValue $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.7
    Set-AnimatedValue $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.7
    Animate-Value $element ([Windows.UIElement]::OpacityProperty) 1 200 $stage.delay
    Animate-Value $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 1 200 $stage.delay
    Animate-Value $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 1 200 $stage.delay
  }
  Set-AnimatedValue $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 0
  Animate-Value $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 1 160 360
  $script:ui.Bubble.IsHitTestVisible=$true
  Restart-SceneTtl 520;Save-Settings
}
function Hide-Quota {
  if($script:collapsed){return}
  Reset-WidgetAutoQuoteSchedule
  $script:collapsed=$true;$script:bubbleEpoch++
  $script:sceneDeadline=0
  if($script:resetPhaseTimer){$script:resetPhaseTimer.Stop();$script:resetPhaseTimer=$null}
  if($script:sceneTimer){$script:sceneTimer.Stop()}
  $script:ui.Bubble.IsHitTestVisible=$false
  Animate-Value $script:ui.SceneText ([Windows.UIElement]::OpacityProperty) 0 160
  foreach($stage in @(@{name='Bubble';delay=100},@{name='Tail';delay=200},@{name='TailNear';delay=300})){
    $element=$script:ui[$stage.name]
    Animate-Value $element ([Windows.UIElement]::OpacityProperty) 0 180 $stage.delay
    Animate-Value $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.7 180 $stage.delay
    Animate-Value $element.RenderTransform ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.7 180 $stage.delay
  }
  if($script:closeTimer){$script:closeTimer.Stop()}
  $script:closeTimer=New-Object Windows.Threading.DispatcherTimer
  $script:closeTimer.Interval=[TimeSpan]::FromMilliseconds(510)
  $script:closeTimer.Add_Tick({param($timer,$event)
    $timer.Stop()
    if($script:collapsed -and $timer-eq $script:closeTimer){Set-BubbleState}
  })
  $script:closeTimer.Start();Save-Settings
}
function Animate-Press([bool]$down) {
  $x=if($down){1.05}else{1.0};$y=if($down){0.88}else{1.0}
  Animate-Value $script:ui.PressScale ([Windows.Media.ScaleTransform]::ScaleXProperty) $x 220 0 $true
  Animate-Value $script:ui.PressScale ([Windows.Media.ScaleTransform]::ScaleYProperty) $y 220 0 $true
}
