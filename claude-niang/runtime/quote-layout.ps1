# Layouts come from three places, cheapest first: memory for this session, the
# reviewed layouts of the built-in quotes (assets\quote-layouts.json, rebuilt by
# tools\quote-layouts.ps1), and a store in the data folder that remembers every
# other searched layout (your own quotes, notices) across restarts. A stored
# layout is only reused after one quick check against this machine's fonts.
$script:quoteLayoutStoreLimit=300
function Initialize-WidgetQuoteLayouts([string]$AppDir,[string]$DataDir=''){
  $script:quoteLayoutMap=@{};$script:quoteLayoutHints=@{};$script:quoteLayoutCache=@{}
  $script:quoteLayoutStore=$null;$script:quoteLayoutStoreFile=$null
  $file=Join-Path $AppDir 'assets\quote-layouts.json'
  if([IO.File]::Exists($file)){
    try{
      $profiles=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json
      foreach($row in $profiles.quotes){
        if($row.text-isnot [string] -or $row.display-isnot [string]){continue}
        if(($row.text-replace '\s','')-cne ($row.display-replace '\s','')){continue}
        $script:quoteLayoutMap[$row.text]=$row.display
        if($row.layout){$script:quoteLayoutHints[$row.display]=$row.layout}
      }
    }catch{Write-WidgetLog $script:dataDir 'widget' ('语录排版文件无法读取：'+$_.Exception.Message)}
  }
  if(!$DataDir){return}
  $script:quoteLayoutStore=[ordered]@{};$script:quoteLayoutStoreFile=Join-Path $DataDir 'cache\quote-layouts.json'
  if(![IO.File]::Exists($script:quoteLayoutStoreFile)){return}
  try{
    if(([IO.FileInfo]::new($script:quoteLayoutStoreFile)).Length-gt 2MB){throw 'store too large'}
    $saved=[IO.File]::ReadAllText($script:quoteLayoutStoreFile,[Text.Encoding]::UTF8)|ConvertFrom-Json
    foreach($row in @($saved.entries)){
      if($row.key-is [string] -and $null-ne $row.fontSize -and $null-ne $row.width -and !$script:quoteLayoutStore.Contains($row.key)){
        $script:quoteLayoutStore[$row.key]=[pscustomobject]@{fontSize=[double]$row.fontSize;width=[double]$row.width}
      }
    }
  }catch{
    $script:quoteLayoutStore=[ordered]@{}
    Write-WidgetLog $DataDir 'widget' ('语录排版缓存无法读取，已重新开始：'+$_.Exception.Message)
  }
}

function Save-WidgetQuoteLayout([string]$Key,$Layout){
  if($null-eq $script:quoteLayoutStore){return}
  if($script:quoteLayoutStore.Contains($Key)){$script:quoteLayoutStore.Remove($Key)}
  while($script:quoteLayoutStore.Count-ge $script:quoteLayoutStoreLimit){$script:quoteLayoutStore.RemoveAt(0)}
  $script:quoteLayoutStore[$Key]=[pscustomobject]@{fontSize=$Layout.fontSize;width=$Layout.width}
  try{
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:quoteLayoutStoreFile))
    $entries=@(foreach($entry in $script:quoteLayoutStore.GetEnumerator()){[ordered]@{key=$entry.Key;fontSize=$entry.Value.fontSize;width=$entry.Value.width}})
    Write-WidgetFileAtomic $script:quoteLayoutStoreFile (@{version=1;entries=$entries}|ConvertTo-Json -Depth 4 -Compress)
  }catch{Write-WidgetLog $script:dataDir 'widget' ('语录排版缓存保存失败：'+$_.Exception.Message)}
}

# Laying out the text is cheap; the per-character line analysis costs more, and
# proving that the glyph outlines fit inside the bubble's ellipse costs the most.
# Searching every candidate in full used to block the UI thread for up to two
# seconds on a quote or notice without a reviewed layout. A candidate is chosen
# only if it fits and scores higher than the best so far, so the checks run
# cheapest first and stop as soon as one fails; the chosen layout is unchanged.
function Get-WidgetQuoteScoreLimit([double]$Size,[int]$Lines){
  return $Size*10-[Math]::Max(0,$Lines-2)*26-($Lines-1)*8
}

function Measure-WidgetQuoteLayout([string]$Value,$TextBlock,$Typeface,[double]$Size,[double]$Width,[int]$ExpectedLines=0,$MustBeat=$null){
  $formatted=[Windows.Media.FormattedText]::new($Value,[Globalization.CultureInfo]::CurrentCulture,[Windows.FlowDirection]::LeftToRight,$Typeface,$Size,$TextBlock.Foreground)
  $formatted.MaxTextWidth=$Width;$formatted.TextAlignment=[Windows.TextAlignment]::Center;$formatted.LineHeight=$Size*1.15
  if($formatted.Height-gt 134){return}
  # Every line is LineHeight tall, so the height gives the line count and the
  # highest score this candidate can reach. A blank line has no characters for
  # the line analysis to count, so text with one skips this shortcut.
  if($Value-notmatch '(^|\n)[^\S\n]*(\n|$)'){
    $lines=[int][Math]::Round($formatted.Height/$formatted.LineHeight)
    if($ExpectedLines-gt 0 -and $lines-ne $ExpectedLines){return}
    if($null-ne $MustBeat -and (Get-WidgetQuoteScoreLimit $Size $lines)-le $MustBeat){return}
  }
  $rows=@{};$indices=[Globalization.StringInfo]::ParseCombiningCharacters($Value)
  for($i=0;$i-lt $indices.Length;$i++){
    $start=$indices[$i];$end=if($i+1-lt $indices.Length){$indices[$i+1]}else{$Value.Length}
    $highlight=$formatted.BuildHighlightGeometry([Windows.Point]::new(0,0),$start,$end-$start)
    if(!$highlight -or $highlight.Bounds.IsEmpty){continue}
    $rect=$highlight.Bounds;$key=[Math]::Round($rect.Top,2)
    if(!$rows.ContainsKey($key)){$rows[$key]=@{left=$rect.Left;right=$rect.Right}}
    else{$rows[$key].left=[Math]::Min($rows[$key].left,$rect.Left);$rows[$key].right=[Math]::Max($rows[$key].right,$rect.Right)}
  }
  if($ExpectedLines-gt 0 -and $rows.Count-ne $ExpectedLines){return}
  $lengths=@($rows.Values|ForEach-Object{$_.right-$_.left})
  $maximum=($lengths|Measure-Object -Maximum).Maximum;$minimum=($lengths|Measure-Object -Minimum).Minimum
  $imbalance=if($maximum-gt 0){1-$minimum/$maximum}else{0}
  $score=(Get-WidgetQuoteScoreLimit $Size $rows.Count)-$imbalance*55
  if($null-ne $MustBeat -and $score-le $MustBeat){return}
  $geometry=$formatted.BuildGeometry([Windows.Point]::new(155-$Width/2,85-$formatted.Height/2))
  if($geometry.Bounds.IsEmpty){return}
  $offsetX=155-($geometry.Bounds.Left+$geometry.Bounds.Width/2)
  $offset=85-($geometry.Bounds.Top+$geometry.Bounds.Height/2)
  $geometry.Transform=[Windows.Media.TranslateTransform]::new($offsetX,$offset)
  $interior=[Windows.Media.EllipseGeometry]::new([Windows.Point]::new(155,85),116,67)
  if($interior.FillContainsWithDetail($geometry)-ne [Windows.Media.IntersectionDetail]::FullyContains){return}
  [pscustomobject]@{fontSize=$Size;width=$Width;lineHeight=$Size*1.15;offsetX=$offsetX;offsetY=$offset;lines=$rows.Count;score=$score}
}

function Get-WidgetQuoteLayout([string]$Value,$TextBlock,[int]$ExpectedLines=0){
  $key=(@($TextBlock.FontFamily.Source,$TextBlock.FontStyle,$TextBlock.FontWeight,$TextBlock.FontStretch,[Globalization.CultureInfo]::CurrentCulture.Name)-join '|')+"`n"+$Value
  if($script:quoteLayoutCache.ContainsKey($key)){return $script:quoteLayoutCache[$key]}
  $typeface=[Windows.Media.Typeface]::new($TextBlock.FontFamily,$TextBlock.FontStyle,$TextBlock.FontWeight,$TextBlock.FontStretch)
  $best=$null;$hint=$script:quoteLayoutHints[$Value]
  $searched=$false
  if(!$hint -and $null-ne $script:quoteLayoutStore -and $script:quoteLayoutStore.Contains($key)){$hint=$script:quoteLayoutStore[$key]}
  # Verify a reviewed or stored layout against this machine's fonts before reusing it.
  if($hint -and $hint.fontSize-ge 6 -and $hint.fontSize-le 32 -and $hint.width-ge 140 -and $hint.width-le 236){$best=Measure-WidgetQuoteLayout $Value $TextBlock $typeface $hint.fontSize $hint.width $ExpectedLines}
  if(!$best){
    $searched=$true
    foreach($size in 32..6){
      if($best -and $best.score-gt $size*10){break}
      foreach($width in @(236,228,220,212,204,196,188,180,172,164,156,148,140)){
        $candidate=Measure-WidgetQuoteLayout $Value $TextBlock $typeface $size $width $ExpectedLines $(if($best){$best.score}else{$null})
        if($candidate -and (!$best -or $candidate.score-gt $best.score)){$best=$candidate}
      }
      if($size-eq 18 -and $best){break}
    }
  }
  if(!$best){throw 'Quote cannot fit inside the bubble'}
  # Remember searched layouts of text without a reviewed one (a stored layout that
  # no longer fits these fonts is replaced by the new search result).
  if($searched -and !$script:quoteLayoutHints.ContainsKey($Value)){Save-WidgetQuoteLayout $key $best}
  if($script:quoteLayoutCache.Count-ge 200){$script:quoteLayoutCache.Clear()}
  $script:quoteLayoutCache[$key]=$best
  return $best
}

function Fit-QuoteText {
  $text=$script:ui.QuoteText;$full=$text.Text;$text.Tag=$full
  $text.HorizontalAlignment=[Windows.HorizontalAlignment]::Center;$text.VerticalAlignment=[Windows.VerticalAlignment]::Center
  $text.TextAlignment=[Windows.TextAlignment]::Center;$text.Margin=[Windows.Thickness]::new(0);$text.Padding=[Windows.Thickness]::new(0)
  $display=$full
  if($script:quoteLayoutMap.ContainsKey($full)){$display=$script:quoteLayoutMap[$full]}
  $expectedLines=if($display.Contains("`n")){($display-split "`n").Count}else{0}
  try{$script:quoteLayout=Get-WidgetQuoteLayout $display $text $expectedLines}
  catch{
    # Reflow only a failed display attempt; Tag retains the full original
    # for the tooltip and copy action, including its explicit line breaks.
    $display=($full-replace '\s+',' ').Trim()
    try{$script:quoteLayout=Get-WidgetQuoteLayout $display $text}
    catch{$display='…';$script:quoteLayout=Get-WidgetQuoteLayout $display $text}
  }
  $text.Text=$display;$text.Width=$script:quoteLayout.width;$text.FontSize=$script:quoteLayout.fontSize;$text.LineHeight=$script:quoteLayout.lineHeight
  $text.LineStackingStrategy=[Windows.LineStackingStrategy]::BlockLineHeight
  $text.RenderTransform=[Windows.Media.TranslateTransform]::new($script:quoteLayout.offsetX,$script:quoteLayout.offsetY)
}

function Set-WidgetSceneLayout {
  $scene=$script:ui.SceneText
  if($script:bubbleMode-eq 'quote' -and $script:quoteLayout){
    [Windows.Controls.Canvas]::SetLeft($scene,155-$script:quoteLayout.width/2);[Windows.Controls.Canvas]::SetTop($scene,18)
    $scene.Width=$script:quoteLayout.width;$scene.Height=134
  }else{
    [Windows.Controls.Canvas]::SetLeft($scene,63);[Windows.Controls.Canvas]::SetTop($scene,22)
    $scene.Width=184;$scene.Height=115
  }
}
