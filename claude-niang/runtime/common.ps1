# C# helpers are compiled once and reused from a cache keyed by their source,
# references and the .NET runtime: each widget start used to run the C# compiler
# about nine times (close to a second). Any problem with the cache falls back to
# compiling in memory, as before.
function Add-WidgetType {
  param([Parameter(Mandatory=$true)][string]$TypeName,[string]$TypeDefinition,[string[]]$Path,[string[]]$ReferencedAssemblies=@(),[switch]$IgnoreWarnings,
    [string]$CacheDirectory=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ClaudeNiang\cache\types'))
  if($TypeName -as [type]){return}
  $compile=@{IgnoreWarnings=$true}
  if($Path){$compile.Path=$Path;$text=(@($Path|ForEach-Object{[IO.File]::ReadAllText($_,[Text.Encoding]::UTF8)}))-join "`n"}
  else{$compile.TypeDefinition=$TypeDefinition;$text=$TypeDefinition}
  $references=@($ReferencedAssemblies|Where-Object{$_})
  if($references.Count){$compile.ReferencedAssemblies=$references}
  try{
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text+'|'+($references-join '|')+'|'+[Environment]::Version+'|'+[IntPtr]::Size)))).Replace('-','').Substring(0,24).ToLowerInvariant()}finally{$sha.Dispose()}
    $assembly=Join-Path $CacheDirectory ($TypeName+'-'+$hash+'.dll')
    if(![IO.File]::Exists($assembly)){
      $null=[IO.Directory]::CreateDirectory($CacheDirectory)
      $temp=Join-Path $CacheDirectory ([Guid]::NewGuid().ToString('N')+'.build.dll')
      try{
        Add-Type @compile -OutputAssembly $temp -OutputType Library -ErrorAction Stop
        # Another process may have finished the same build first; either copy is identical.
        try{[IO.File]::Move($temp,$assembly)}catch{}
      }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
      foreach($old in @(Get-ChildItem -LiteralPath $CacheDirectory -Filter ($TypeName+'-*.dll') -ErrorAction SilentlyContinue)){
        if($old.FullName-ne $assembly){try{Remove-Item -LiteralPath $old.FullName -ErrorAction Stop}catch{}}
      }
    }
    Add-Type -Path $assembly -ErrorAction Stop
  }catch{}
  if(!($TypeName -as [type])){Add-Type @compile}
}

function Get-WidgetKnownFolderPath([Guid]$Id){
  if(!('ClaudeWidgetKnownFolders' -as [type])){
    Add-WidgetType -TypeName ClaudeWidgetKnownFolders -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class ClaudeWidgetKnownFolders {
 [DllImport("shell32.dll")]static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
 public static string Read(Guid id){
  IntPtr value=IntPtr.Zero;
  try{Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(ref id,0x10000,IntPtr.Zero,out value));return Marshal.PtrToStringUni(value);}
  finally{if(value!=IntPtr.Zero)Marshal.FreeCoTaskMem(value);}
 }
}
'@
  }
  # KF_FLAG_NO_PACKAGE_REDIRECTION gives Task Scheduler, Explorer and the
  # Microsoft Store build of Claude the same physical location as the installer.
  return [ClaudeWidgetKnownFolders]::Read($Id)
}
function Get-WidgetLocalApplicationData {
  return Get-WidgetKnownFolderPath ([Guid]'F1B32785-6FBA-4FCF-9D55-7B8E7F157091')
}
function Read-WidgetJsonFile([string]$File) {
  if(Test-Path -LiteralPath $File){return (Get-Content -LiteralPath $File -Raw -Encoding UTF8|ConvertFrom-Json)}
  return $null
}
# Every state file is written through a unique temporary file and an atomic
# replace. Another process reading the file (the worker, the supervisor, an
# antivirus scan) briefly blocks the replace on Windows, so it is retried
# before giving up. -Backup keeps the previous version as <file>.bak.
function Write-WidgetFileAtomic([string]$File,[string]$Text,[switch]$Bom,[switch]$Backup){
  $temp=$File+'.'+$PID+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
  try{
    [IO.File]::WriteAllText($temp,$Text,[Text.UTF8Encoding]::new([bool]$Bom))
    $backupFile=if($Backup){$File+'.bak'}else{[System.Management.Automation.Language.NullString]::Value}
    for($attempt=1;;$attempt++){
      try{
        if([IO.File]::Exists($File)){[IO.File]::Replace($temp,$File,$backupFile,$true)}else{[IO.File]::Move($temp,$File)}
        return
      }catch{if($attempt-ge 5){throw};Start-Sleep -Milliseconds 15}
    }
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
# User state (settings, notices) keeps a .bak copy; -NoBackup is for status and
# request files that are rewritten all the time and have nothing to restore.
function Write-WidgetJson($file,$value,[switch]$NoBackup){Write-WidgetFileAtomic $file ($value|ConvertTo-Json -Depth 6) -Backup:(!$NoBackup)}
