function Get-WidgetKnownFolderPath([Guid]$Id){
  if(!('ClaudeWidgetKnownFolders' -as [type])){
    Add-Type -TypeDefinition @'
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
