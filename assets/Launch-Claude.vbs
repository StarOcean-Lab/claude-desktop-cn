' Portable launcher: keep userData, config library, and logs inside the
' install directory. The direct claude.exe shortcut would fall back to
' %LOCALAPPDATA%\Claude-3p.
Option Explicit
Dim fso, shell, base, data, exe
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)
data = base & "\data"
exe = base & "\app\claude.exe"
shell.Environment("Process")("CLAUDE_USER_DATA_DIR") = data
shell.Run """" & exe & """ --user-data-dir=""" & data & """", 1, False
