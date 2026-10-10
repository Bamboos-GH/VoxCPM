' VoxCPM2 TTS 服务 - 无窗口静默启动器
' 由 service.ps1 的 autostart 动作创建快捷方式到启动文件夹
Dim fso, sh, root, ps, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

root = fso.GetParentFolderName(WScript.ScriptFullName)
ps   = "powershell.exe"
cmd  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & root & "\service.ps1"" start -Port 8099"

' 0 = 隐藏窗口, False = 不等待
sh.Run """" & ps & """ " & cmd, 0, False
