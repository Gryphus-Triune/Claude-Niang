param([string]$OutDir=(Join-Path $PSScriptRoot 'dist'),[string]$NodePath='')
$ErrorActionPreference='Stop'
if(!$NodePath){
  . (Join-Path $PSScriptRoot 'claude-niang\runtime\install-preflight.ps1')
  $node=Find-WidgetNode;if(!$node){throw '请先安装 Node.js LTS 版本（20 或更新）。'};$NodePath=$node.path
}
$outRoot=[IO.Path]::GetFullPath($OutDir).TrimEnd('\')
$null=[IO.Directory]::CreateDirectory($outRoot)
$buildRoot=Join-Path $outRoot ('.build-'+[Guid]::NewGuid().ToString('N'))
$releaseRoot=Join-Path $buildRoot 'Claude娘额度挂件'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
function Get-ReleaseFileSha256([string]$Path){
  $sha=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
  try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
  finally{$stream.Dispose();$sha.Dispose()}
}
function New-ReleaseZip([string]$Source,[string]$Target,[string]$Prefix=''){
  $stream=[IO.File]::Open($Target,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  $archive=$null
  try{
    $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false,[Text.Encoding]::UTF8)
    foreach($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File|Sort-Object FullName)){
      $relative=$file.FullName.Substring($Source.TrimEnd('\').Length+1).Replace('\','/')
      $entry=$archive.CreateEntry(($Prefix+$relative),[IO.Compression.CompressionLevel]::Optimal)
      $input=[IO.File]::OpenRead($file.FullName);$output=$entry.Open()
      try{$input.CopyTo($output)}finally{$input.Dispose();$output.Dispose()}
    }
  }finally{if($archive){$archive.Dispose()};$stream.Dispose()}
}
try{
  & $NodePath (Join-Path $PSScriptRoot 'tools\release.mjs') --source $PSScriptRoot --output $releaseRoot
  if($LASTEXITCODE-ne 0){throw '发布文件准备失败。'}
  $package=Get-Content -LiteralPath (Join-Path $releaseRoot 'claude-niang\package.json') -Raw -Encoding UTF8|ConvertFrom-Json
  $extensionDir=Join-Path $releaseRoot 'Claude桌面扩展';$null=[IO.Directory]::CreateDirectory($extensionDir)
  New-ReleaseZip (Join-Path $releaseRoot 'claude-niang\extension') (Join-Path $extensionDir 'claude-niang-usage.mcpb')
  $checks=@(Get-ChildItem -LiteralPath $releaseRoot -Recurse -File|Sort-Object FullName|ForEach-Object{(Get-ReleaseFileSha256 $_.FullName)+'  '+$_.FullName.Substring($releaseRoot.Length+1).Replace('\','/')})
  [IO.File]::WriteAllText((Join-Path $releaseRoot 'CHECKSUMS.sha256'),($checks-join "`n")+"`n",[Text.UTF8Encoding]::new($false))
  $target=Join-Path $outRoot ('claude-niang-v'+$package.version+'-windows.zip')
  New-ReleaseZip $releaseRoot $target 'Claude娘额度挂件/'
  $hash=Get-ReleaseFileSha256 $target
  [IO.File]::WriteAllText(($target+'.sha256'),$hash+'  '+[IO.Path]::GetFileName($target)+"`n",[Text.UTF8Encoding]::new($false))
  Write-Host ('已生成：'+$target)
}finally{
  # Delete only the unique staging directory created by this invocation.
  $resolved=[IO.Path]::GetFullPath($buildRoot)
  if($resolved.StartsWith($outRoot+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved)-match '^\.build-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $resolved)){
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
