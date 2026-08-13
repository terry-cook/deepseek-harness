' Start the DeepSeek Harness web server with no console window, so it outlives
' the terminal that launched it. Closing a PowerShell window sends
' CTRL_CLOSE_EVENT to every process attached to that console, which is why a
' foreground `dsh web` dies with its terminal.
'
' Usage: wscript dsh-web.vbs [/port:3080] [/dsh:<dsh.cmd>] [/log:<file>]
'
' Every argument is optional: the port defaults to 3080, the launcher is found
' under the npm global prefix or on PATH, and the log lands in %LOCALAPPDATA%.
' Running this twice is safe — it stands down when a server is already up.
'
' Install shortcuts that pass these arguments with install-dsh-shortcuts.ps1.
Option Explicit

Const DEFAULT_PORT = "3080"
Const MAX_LOG_BYTES = 5242880

Dim fso, shell
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

Dim port, dshCmd, logFile
port = NamedArg("port", DEFAULT_PORT)
dshCmd = NamedArg("dsh", DefaultDshCommand())
logFile = NamedArg("log", DefaultLogFile())

' Two signals, because neither covers the whole window on its own: a bound
' server answers on the port whatever started it, and a server still in its
' 20-40 second cold start exists only as a process.
If ServerListening(port) Then WScript.Quit 0
If DshProcessStarting(port) Then WScript.Quit 0

EnsureParentFolder logFile
RotateLog logFile

' Window style 0 hides the console; False returns without waiting. The child
' outlives this script and is attached to no window the user can close.
shell.Run "cmd /c """"" & dshCmd & """ web --port " & port & " >> """ & logFile & """ 2>&1""", 0, False

' Value of a /name:value argument, or fallback when it was not passed.
Function NamedArg(argName, fallback)
  If WScript.Arguments.Named.Exists(argName) Then
    NamedArg = WScript.Arguments.Named.Item(argName)
  Else
    NamedArg = fallback
  End If
End Function

' The `dsh` launcher installed by `npm i -g @deepseek-ai/dsh`, falling back to
' a bare name for cmd to resolve against PATH.
Function DefaultDshCommand()
  Dim candidate
  candidate = shell.ExpandEnvironmentStrings("%APPDATA%\npm\dsh.cmd")
  If fso.FileExists(candidate) Then
    DefaultDshCommand = candidate
  Else
    DefaultDshCommand = "dsh"
  End If
End Function

' Per-user log location, alongside anything else this tooling writes.
Function DefaultLogFile()
  DefaultLogFile = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\dsh\web.log")
End Function

' True when something already answers on the port. Proxies are bypassed
' because a configured proxy without a localhost exception would otherwise
' report a loopback server as unreachable.
Function ServerListening(listenPort)
  Dim http
  ServerListening = False
  On Error Resume Next
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setProxy 1
  http.setTimeouts 2000, 2000, 5000, 5000
  http.Open "GET", "http://127.0.0.1:" & listenPort & "/", False
  http.Send
  ServerListening = (Err.Number = 0)
  On Error GoTo 0
End Function

' True when a dsh server for this port exists but has not bound yet. The match
' is deliberately per-port rather than "any dsh process": a server on another
' port is not a reason to stand down. This script always passes --port, so a
' cold start it launched is always recognized; a server started by hand without
' the flag is only recognized once it answers on the port.
Function DshProcessStarting(listenPort)
  Dim wmi, procs, proc, commandLine
  DshProcessStarting = False
  On Error Resume Next
  Set wmi = GetObject("winmgmts:\\.\root\cimv2")
  Set procs = wmi.ExecQuery("Select CommandLine from Win32_Process Where Name = 'node.exe'")
  If Err.Number <> 0 Then
    On Error GoTo 0
    Exit Function
  End If
  On Error GoTo 0
  For Each proc In procs
    If Not IsNull(proc.CommandLine) Then
      commandLine = LCase(proc.CommandLine)
      If InStr(commandLine, "\dsh\lib\bin.js") > 0 Then
        If HasPortFlag(commandLine, listenPort) Then DshProcessStarting = True
      End If
    End If
  Next
End Function

' True when the command line names exactly this port, so that port 308 does not
' match a server running on 3080.
Function HasPortFlag(commandLine, listenPort)
  Dim needle, at, following
  needle = "--port " & listenPort
  HasPortFlag = False
  at = InStr(commandLine, needle)
  If at = 0 Then Exit Function
  following = Mid(commandLine, at + Len(needle), 1)
  HasPortFlag = (following = "" Or Not IsNumeric(following))
End Function

' Create the log's folder when a custom /log path points somewhere new.
Sub EnsureParentFolder(path)
  Dim parent
  parent = fso.GetParentFolderName(path)
  If parent <> "" And Not fso.FolderExists(parent) Then fso.CreateFolder parent
End Sub

' Discard the log once it passes the ceiling; this output is a diagnostic tail,
' not a record worth archiving.
Sub RotateLog(path)
  If Not fso.FileExists(path) Then Exit Sub
  If fso.GetFile(path).Size > MAX_LOG_BYTES Then fso.DeleteFile path
End Sub
