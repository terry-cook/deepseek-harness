' Open the DeepSeek Harness web UI as a chromeless desktop window: start the
' server when it is not already up, wait for it to answer, then hand the URL to
' a Chromium-family browser in --app mode.
'
' Usage: wscript dsh-app.vbs [/port:3080] [/dsh:<dsh.cmd>] [/log:<file>]
'                            [/title:<window title>] [/wait:<seconds>]
'
' Every argument is optional and the server arguments are forwarded verbatim to
' dsh-web.vbs, which must sit in the same folder.
'
' Install shortcuts that pass these arguments with install-dsh-shortcuts.ps1.
Option Explicit

Const DEFAULT_PORT = "3080"
Const DEFAULT_TITLE = "DeepSeek Harness"
' Generous because this also runs at logon, where a cold start competes with
' every other startup task. The wait ends as soon as the server answers.
Const DEFAULT_WAIT_SECONDS = 180

Dim fso, shell
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

Dim port, title, waitSeconds, url
port = NamedArg("port", DEFAULT_PORT)
title = NamedArg("title", DEFAULT_TITLE)
waitSeconds = CInt(NamedArg("wait", CStr(DEFAULT_WAIT_SECONDS)))
url = "http://127.0.0.1:" & port & "/"

' Raise the existing window instead of stacking a second one. Only the window
' is evidence: a browser already running takes the --app request over IPC and
' the process that carried it exits immediately, so its command line is gone.
If ActivateExistingWindow(title) Then WScript.Quit 0

StartServer

Dim waited
waited = 0
Do While Not ServerUp(url)
  If waited >= waitSeconds Then
    MsgBox "dsh web did not come up within " & waitSeconds & " seconds." & vbCrLf & vbCrLf & _
           "Log: " & ServerLogPath(), vbExclamation, title
    WScript.Quit 1
  End If
  WScript.Sleep 1000
  waited = waited + 1
Loop

' Re-check before opening: during a cold start no window exists yet, so two
' launchers can both reach this point and would otherwise open one window each.
If Not ActivateExistingWindow(title) Then OpenWindow url

' Value of a /name:value argument, or fallback when it was not passed.
Function NamedArg(argName, fallback)
  If WScript.Arguments.Named.Exists(argName) Then
    NamedArg = WScript.Arguments.Named.Item(argName)
  Else
    NamedArg = fallback
  End If
End Function

' Run the sibling server script, forwarding only the arguments it accepts. It
' stands down by itself when a server is already running.
Sub StartServer
  Dim command
  command = "wscript.exe """ & fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "dsh-web.vbs") & """"
  command = command & " /port:" & port
  If WScript.Arguments.Named.Exists("dsh") Then command = command & " /dsh:""" & WScript.Arguments.Named.Item("dsh") & """"
  If WScript.Arguments.Named.Exists("log") Then command = command & " /log:""" & WScript.Arguments.Named.Item("log") & """"
  shell.Run command, 0, True
End Sub

' Where the server writes, for the timeout message only.
Function ServerLogPath()
  ServerLogPath = NamedArg("log", shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\dsh\web.log"))
End Function

' True when a window with this title existed and was brought to the front.
Function ActivateExistingWindow(windowTitle)
  On Error Resume Next
  ActivateExistingWindow = shell.AppActivate(windowTitle)
  If Err.Number <> 0 Then ActivateExistingWindow = False
  On Error GoTo 0
End Function

' True once the server answers a request, which is later than the port opening.
Function ServerUp(targetUrl)
  Dim http
  ServerUp = False
  On Error Resume Next
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setProxy 1
  http.setTimeouts 2000, 2000, 5000, 5000
  http.Open "GET", targetUrl, False
  http.Send
  If Err.Number = 0 Then ServerUp = (http.Status = 200)
  On Error GoTo 0
End Function

' Chromium browsers render --app as a window with no address bar or tab strip.
' Anything else still gets an ordinary tab in the default browser.
Sub OpenWindow(targetUrl)
  Dim browser
  browser = FindBrowser()
  If browser = "" Then
    shell.Run targetUrl, 1, False
  Else
    shell.Run """" & browser & """ --app=" & targetUrl, 1, False
  End If
End Sub

' First installed Chromium-family browser, located through the App Paths keys
' that installers register, rather than assumed install directories.
Function FindBrowser()
  Dim executables, hives, i, j, path
  executables = Array("msedge.exe", "chrome.exe")
  hives = Array("HKLM", "HKCU")
  FindBrowser = ""
  For i = 0 To UBound(executables)
    For j = 0 To UBound(hives)
      If FindBrowser = "" Then
        path = RegValue(hives(j) & "\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" & executables(i) & "\")
        If path <> "" Then
          If fso.FileExists(path) Then FindBrowser = path
        End If
      End If
    Next
  Next
End Function

' Registry read that answers with an empty string instead of raising when the
' key is absent, which is the ordinary case for a browser that is not installed.
Function RegValue(key)
  On Error Resume Next
  RegValue = shell.RegRead(key)
  If Err.Number <> 0 Then RegValue = ""
  On Error GoTo 0
End Function
