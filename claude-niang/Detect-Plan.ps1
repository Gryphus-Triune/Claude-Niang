param([switch]$Json)
# 检测套餐：用 Claude 娘的登录读一次 claude.ai，打印套餐与各额度窗口。
$ErrorActionPreference='Stop'
$configFile=Join-Path $PSScriptRoot 'installation.json'
if(!(Test-Path -LiteralPath $configFile)){Write-Host '请先运行「安装Claude娘.cmd」。' -ForegroundColor Red;exit 1}
$config=Get-Content -LiteralPath $configFile -Raw -Encoding UTF8|ConvertFrom-Json
$nodePath=[string]$config.nodePath
if(!$nodePath -or !(Test-Path -LiteralPath $nodePath)){$command=Get-Command node.exe -ErrorAction SilentlyContinue;if($command){$nodePath=$command.Source}}
if(!$nodePath){throw '需要 Node.js 20 或更新版本。'}
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$arguments=@((Join-Path $PSScriptRoot 'runtime\detect-plan.mjs'))
if($Json){$arguments+='--json'}
& $nodePath @arguments
exit $LASTEXITCODE
