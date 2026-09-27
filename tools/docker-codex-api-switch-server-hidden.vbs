Option Explicit

Dim arguments
Dim command
Dim exitCode
Dim fileSystem
Dim nodePath
Dim scriptPath
Dim shell

Set arguments = WScript.Arguments
If arguments.Count <> 2 Then
  WScript.Quit 64
End If

nodePath = arguments(0)
scriptPath = arguments(1)

Set fileSystem = CreateObject("Scripting.FileSystemObject")
If Not fileSystem.FileExists(nodePath) Or Not fileSystem.FileExists(scriptPath) Then
  WScript.Quit 2
End If

Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = fileSystem.GetParentFolderName(scriptPath)
command = QuoteArgument(nodePath) & " " & QuoteArgument(scriptPath)

' Window style 0 keeps the console child hidden; wait keeps Task Scheduler ownership intact.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function QuoteArgument(value)
  QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
