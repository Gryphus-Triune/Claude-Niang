param([string]$AppDir=(Join-Path (Split-Path $PSScriptRoot -Parent) 'claude-niang'))
# Rebuilds the reviewed layouts in claude-niang\assets\quote-layouts.json: for
# every built-in quote, the font size and width the widget's search picks for
# its display text. At runtime each stored layout is checked once against the
# machine's fonts (a few milliseconds) instead of searched. Run in Windows
# PowerShell (STA) after changing quotes or the bubble layout:
#   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tools\quote-layouts.ps1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $AppDir 'runtime\log.ps1')
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $AppDir 'runtime\quote-layout.ps1'),[Text.Encoding]::UTF8)))
$window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $AppDir 'widget.xaml'),[Text.Encoding]::UTF8))
$text=$window.FindName('QuoteText')
$file=Join-Path $AppDir 'assets\quote-layouts.json'
$saved=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json
$script:quoteLayoutMap=@{};$script:quoteLayoutHints=@{};$script:quoteLayoutCache=@{};$script:quoteLayoutStore=$null
$quote={param($value)$value|ConvertTo-Json -Compress}
$rows=foreach($row in $saved.quotes){
  $lines=if($row.display.Contains("`n")){($row.display-split "`n").Count}else{0}
  $layout=Get-WidgetQuoteLayout $row.display $text $lines
  "    {`n      `"text`": "+(& $quote $row.text)+",`n      `"display`": "+(& $quote $row.display)+",`n      `"layout`": { `"fontSize`": "+$layout.fontSize+", `"width`": "+$layout.width+" }`n    }"
}
$json="{`n  `"version`": 1,`n  `"quotes`": [`n"+(@($rows)-join ",`n")+"`n  ]`n}`n"
[IO.File]::WriteAllText($file,$json,[Text.UTF8Encoding]::new($false))
'{0} layouts written to {1}' -f @($rows).Count,$file
