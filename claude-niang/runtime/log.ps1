# Shared diagnostic log for the widget, its supervisor and the quota worker
# (runtime/log.mjs writes the same format): <dataDir>\logs\claude-niang.log,
# rolled over to claude-niang.1.log at 1 MB. Only short lifecycle and failure
# notes belong here, never cookies, tokens or organization ids.
function Write-WidgetLog {
  param([string]$DataDir,[string]$Source,$Message)
  try{
    if(!$DataDir){return}
    $text=if($Message-is [Management.Automation.ErrorRecord]){$Message.Exception.Message}elseif($Message-is [Exception]){$Message.Message}else{[string]$Message}
    $text=([string]$text-replace '\s+',' ').Trim()
    if(!$text){return}
    if($text.Length-gt 1000){$text=$text.Substring(0,1000)+'...'}
    # A failure repeated by a timer is written once a minute, not on every tick.
    if($null-eq $script:widgetLogRecent){$script:widgetLogRecent=@{}}
    $now=[DateTime]::UtcNow;$key=$Source+'|'+$text
    if($script:widgetLogRecent.ContainsKey($key) -and ($now-$script:widgetLogRecent[$key]).TotalSeconds-lt 60){return}
    if($script:widgetLogRecent.Count-ge 200){$script:widgetLogRecent.Clear()}
    $script:widgetLogRecent[$key]=$now
    $directory=Join-Path $DataDir 'logs'
    $null=[IO.Directory]::CreateDirectory($directory)
    $file=Join-Path $directory 'claude-niang.log'
    $info=[IO.FileInfo]::new($file)
    if($info.Exists -and $info.Length-ge 1MB){
      $previous=Join-Path $directory 'claude-niang.1.log'
      try{if([IO.File]::Exists($previous)){[IO.File]::Delete($previous)};[IO.File]::Move($file,$previous)}catch{}
    }
    $line=[DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff zzz',[Globalization.CultureInfo]::InvariantCulture)+' ['+$Source+' '+$PID+'] '+$text+"`r`n"
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($line)
    # AppendData access makes every line a single atomic append, so the widget,
    # the supervisor and the worker can share one file.
    $stream=[IO.FileStream]::new($file,[IO.FileMode]::Append,[Security.AccessControl.FileSystemRights]::AppendData,[IO.FileShare]'ReadWrite, Delete',4096,[IO.FileOptions]::None)
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
  }catch{}
}
