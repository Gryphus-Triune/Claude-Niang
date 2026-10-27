# Widget preferences in <dataDir>\settings.json. Each field is read on its
# own, so one malformed value never discards the other valid preferences.

# The saved number when it is finite and inside [Min, Max]; otherwise $null.
function Get-WidgetSettingNumber($Settings,[string]$Name,[double]$Min=-100000,[double]$Max=100000) {
  if($null-eq $Settings -or $null-eq $Settings.$Name){return $null}
  try{$value=[double]$Settings.$Name}catch{return $null}
  if([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value-lt $Min -or $value-gt $Max){return $null}
  return $value
}

# $true only for a saved JSON true; $null when the field is absent.
function Get-WidgetSettingFlag($Settings,[string]$Name) {
  if($null-eq $Settings -or $null-eq $Settings.$Name){return $null}
  return ($Settings.$Name-is [bool] -and $Settings.$Name)
}

# Applies the saved preferences over the defaults already set in $script:.
function Import-WidgetSettings($Settings) {
  $value=Get-WidgetSettingNumber $Settings 'right';if($null-ne $value){$script:offsetRight=$value}
  $value=Get-WidgetSettingNumber $Settings 'bottom';if($null-ne $value){$script:offsetBottom=$value}
  $value=Get-WidgetSettingNumber $Settings 'scale' 0.6 2.5;if($null-ne $value){$script:scale=$value}
  # Preserve the previous combined size until the bubble is adjusted separately.
  $script:bubbleScale=$script:scale
  $value=Get-WidgetSettingNumber $Settings 'bubbleScale' 0.6 2.5;if($null-ne $value){$script:bubbleScale=$value}
  if($Settings.layoutVersion-eq 2){
    $value=Get-WidgetSettingNumber $Settings 'left';if($null-ne $value){$script:offsetLeft=$value}
    if(@('left','right','free')-contains $Settings.anchor){$script:anchor=$Settings.anchor}
    if(@('left','right')-contains $Settings.side){$script:side=$Settings.side}
  }else{$script:offsetBottom=0;if($script:offsetRight-gt 18){$script:anchor='free'}}
  $flag=Get-WidgetSettingFlag $Settings 'soundOn';if($null-ne $flag){$script:soundOn=$flag}
  $value=Get-WidgetSettingNumber $Settings 'soundVolume' ([double]::MinValue) ([double]::MaxValue);if($null-ne $value){$script:soundVolume=[Math]::Min(1.0,[Math]::Max(0.0,$value))}
  $flag=Get-WidgetSettingFlag $Settings 'bubbleTapAdvance';if($null-ne $flag){$script:bubbleTapAdvance=$flag}
  $flag=Get-WidgetSettingFlag $Settings 'hideMenu';if($null-ne $flag){$script:hideMenu=$flag}
  $flag=Get-WidgetSettingFlag $Settings 'followHost';if($null-ne $flag){$script:followHost=$flag}
  $flag=Get-WidgetSettingFlag $Settings 'desktopTopmost';if($null-ne $flag){$script:desktopTopmost=$flag}
  $value=Get-WidgetSettingNumber $Settings 'desktopLeft';if($null-ne $value){$script:desktopLeft=$value}
  $value=Get-WidgetSettingNumber $Settings 'desktopTop';if($null-ne $value){$script:desktopTop=$value}
  if($Settings.characterId-is [string]){$script:characterId=$Settings.characterId}
}

function Save-Settings {
  Write-WidgetJson $script:settingsFile @{
    layoutVersion=2;right=$script:offsetRight;left=$script:offsetLeft;bottom=$script:offsetBottom;anchor=$script:anchor;side=$script:side
    scale=$script:scale;bubbleScale=$script:bubbleScale;collapsed=$script:collapsed
    soundOn=$script:soundOn;soundVolume=$script:soundVolume;bubbleTapAdvance=$script:bubbleTapAdvance;hideMenu=$script:hideMenu
    followHost=$script:followHost;desktopTopmost=$script:desktopTopmost;desktopLeft=$script:desktopLeft;desktopTop=$script:desktopTop
    characterId=$script:characterId;autoQuoteEnabled=$script:autoQuoteEnabled;autoQuoteIntervalSeconds=$script:autoQuoteIntervalSeconds
    preferredOrg=$script:preferredOrg;lowQuotaAlert=$script:lowQuotaAlert;resetAlert=$script:resetAlert
  }
}
