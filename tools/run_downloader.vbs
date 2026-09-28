' ============================================================================
'  zhu-ye-reader : ctfile book downloader launcher (idempotent, detached)
'
'  Why a VBS launcher:
'    1. Idempotent - exits at once if a downloader is already running, so it can
'       never start a second instance that would fight over the same .part files.
'    2. Detached    - launched via explorer.exe so the python process does NOT
'       belong to the agent/session process tree. It survives after the session
'       ends (this is what cost us 3.6 idle days before).
'    3. Logs land in data\logs\dl2-YYYY-MM-DD.log
'
'  Strategy notes (measured 2026-09-28, see tools/_diag_sustain.py):
'    * Burst quota is only ~9MB at ~1MB/s, then a hard 16KB/s floor.
'    * The 16KB/s floor is USABLE CONTINUOUSLY - it is not a block.
'    * Quota is shared per account, NOT per CDN host => no gain from relinking hosts.
'    * Resting R seconds pays back R x 16KB/s, so anything >576s is a net LOSS.
'      => rest-max 0 : never rest, just re-handshake and keep pulling the floor.
'    * HTTP 403/404/410/503 means the link expired / host refused - NOT throttling.
'      Measured: after a 900s rest the retry finished in 11s. So: relink at once.
'    * Slow-block threshold must sit BELOW the floor (16KB/s) or normal floor-rate
'      downloads get misjudged as "throttled" => slow-bytes 64KB per 10s = 6.5KB/s.
'    * At floor rate a 100MB book needs ~6400 active seconds => pack-timeout 10800.
' ============================================================================
Option Explicit

Dim PY, ROOT, CMD
Dim sh, wmi, procs, p, running

PY   = "C:\Users\admin\.workbuddy\binaries\python\versions\3.13.12\python.exe"
ROOT = "F:\asc_workspace\code\aicode\zhu-ye-dianzishu"

Set sh = CreateObject("WScript.Shell")

' ---- idempotency: bail out if a downloader process already exists ----
running = False
On Error Resume Next
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='python.exe'")
On Error GoTo 0
For Each p In procs
  If Not IsNull(p.CommandLine) Then
    If InStr(1, p.CommandLine, "ctfile_downloader2", vbTextCompare) > 0 Then
      running = True
    End If
  End If
Next
If running Then
  WScript.Quit 0
End If

sh.CurrentDirectory = ROOT
CMD = """" & PY & """" & " tools\ctfile_downloader2.py" & _
      " --manifest data\manifest.jsonl" & _
      " --root E:\chinabook" & _
      " --state data\download-state.jsonl" & _
      " --workers 1 --limit 0 --loop" & _
      " --rest-min 0 --rest-max 0" & _
      " --max-relinks 8 --relink-backoff 5" & _
      " --slow-window 10 --slow-bytes 65536" & _
      " --pack-timeout 10800 --max-rest-cycles 12" & _
      " --max-attempts 3 --delay 1"

' 0 = hidden window, False = do not wait for it to exit
sh.Run CMD, 0, False
