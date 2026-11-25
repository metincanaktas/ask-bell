# Ask Bell for Claude Code - Windows installer (Windows PowerShell 5.1 or PowerShell 7).
#
#   Install:       irm https://raw.githubusercontent.com/metincanaktas/ask-bell/main/install.ps1 | iex
#   Uninstall:     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/metincanaktas/ask-bell/main/install.ps1))) -Uninstall
#   From a clone:  powershell -ExecutionPolicy Bypass -File .\install.ps1 [-Uninstall] [-Settings <path>]
#
# Writes the hook script to <config>\ask-bell\bell.ps1 and adds two hooks to
# <config>\settings.json, where <config> is $env:CLAUDE_CONFIG_DIR or
# ~\.claude. The settings file is backed up first, only this tool's entries
# are added or removed, the result is validated and the backup is restored
# on any failure. Running it twice changes nothing. Needs nothing beyond
# Windows itself. The hook uses the exec form ("args"), Claude Code 2.1.139+.
#
# This file stays ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# It never calls "exit": under "irm | iex" that would close the window.
param(
    [Alias('Uninstall')][switch]$AskBellUninstall,
    [Alias('Settings')][string]$AskBellSettings = ''
)

& {
    param([bool]$Remove, [string]$Target)

    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'

    $Events = @(
        @{ Event = 'PreToolUse'; Matcher = 'AskUserQuestion' },
        @{ Event = 'Notification'; Matcher = 'permission_prompt' }
    )
    $PSObj = [System.Management.Automation.PSCustomObject]
    $Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

    $BellScript = @'
# Ask Bell - Claude Code hook for Windows (written by install.ps1).
#
# Plays a sound and shows a notification when Claude Code asks you a
# question (PreToolUse, matcher AskUserQuestion) or waits for your
# permission (Notification, matcher permission_prompt). Claude Code runs it
# with "async": true, so it never blocks the session. Prints nothing.
#
#   ASK_BELL_SOUND=C:\path\file.wav   sound to play (default: Windows Notify)
#   ASK_BELL_DRY_RUN=1 or -DryRun     print the notification text instead
param([switch]$DryRun)
$ErrorActionPreference = 'SilentlyContinue'

$raw = ''
try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
try { if ([Console]::IsInputRedirected) { $raw = [Console]::In.ReadToEnd() } } catch {}
$d = $null
if ($raw.Length -gt 0 -and $raw.Length -le 200000) { try { $d = ConvertFrom-Json -InputObject $raw } catch { $d = $null } }

function Clean($x) { if ($x -is [string]) { return ($x -replace '\s+', ' ').Trim() } return '' }
function Field($o, [string]$name) {
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $p = $o.PSObject.Properties[$name]
        if ($null -ne $p) { return , $p.Value }
    }
    return $null
}

$cwd = Clean (Field $d 'cwd')
$project = ($cwd.TrimEnd('\', '/') -split '[\\/]')[-1]
if (-not $project) { $project = 'Claude' }
$tool = Clean (Field $d 'tool_name')
$kind = Clean (Field $d 'notification_type')
$hookEvent = Clean (Field $d 'hook_event_name')
$action = 'is waiting for you'
$detail = Clean (Field $d 'message')
if ($tool -eq 'AskUserQuestion') {
    $action = 'is asking a question'
    $qs = Field (Field $d 'tool_input') 'questions'
    $q = $null
    if ($qs -is [System.Array] -and $qs.Count -gt 0) { $q = $qs[0] }
    $h = Clean (Field $q 'header')
    $m = Clean (Field $q 'question')
    if ($h -and $m) { $detail = "${h}: $m" } elseif ($h) { $detail = $h } else { $detail = $m }
} elseif ($kind -eq 'permission_prompt' -or $hookEvent -eq 'PermissionRequest') {
    $action = 'is waiting for your permission'
    if (-not $detail) { $detail = $tool }
} elseif ($kind.StartsWith('elicitation')) {
    $action = 'is asking a question'
}
$body = "$project $action"
if ($detail) { $body = "${body}: $detail" }
if ($body.Length -gt 180) { $body = $body.Substring(0, 179) + [char]0x2026 }

if ($DryRun -or $env:ASK_BELL_DRY_RUN -eq '1') {
    Write-Output "Claude Code | $body"
    exit 0
}

# Notification: a Windows toast through WinRT, shown under Windows PowerShell's name.
try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $text = [System.Security.SecurityElement]::Escape($body)
    $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>Claude Code</text><text>$text</text></binding></visual><audio silent=`"true`"/></toast>")
    $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
} catch {}

# Sound: a .wav that ships with Windows, played to the end.
try {
    $wav = $env:ASK_BELL_SOUND
    if (-not $wav -or -not (Test-Path -LiteralPath $wav)) { $wav = Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav' }
    if (-not (Test-Path -LiteralPath $wav)) { $wav = Join-Path $env:WINDIR 'Media\chimes.wav' }
    (New-Object System.Media.SoundPlayer $wav).PlaySync()
} catch {
    try { [System.Media.SystemSounds]::Asterisk.Play(); Start-Sleep -Milliseconds 900 } catch {}
}
exit 0
'@

    function Say([string]$Text) { Write-Host $Text }

    # JSON keys are case-sensitive; PowerShell property lookup is not.
    function Get-Exact($Obj, [string]$Name) {
        foreach ($p in $Obj.PSObject.Properties) { if ($p.Name -ceq $Name) { return $p } }
        return $null
    }
    function Test-CaseClash($Obj, [string]$Name) {
        foreach ($p in $Obj.PSObject.Properties) { if ($p.Name -eq $Name -and $p.Name -cne $Name) { return $true } }
        return $false
    }

    function Read-Utf8([string]$Path) {
        try { return [System.IO.File]::ReadAllText($Path, $Utf8Strict) }
        catch { throw "cannot read $Path as UTF-8 ($($_.Exception.Message)); file left untouched" }
    }

    # Ours: "powershell.exe" with ".../ask-bell/bell.ps1" in its "args", from any folder.
    function Test-Ours($h) {
        if ($h -isnot $PSObj) { return $false }
        $c = Get-Exact $h 'command'
        if ($null -eq $c -or $c.Value -ne 'powershell.exe') { return $false }
        $a = Get-Exact $h 'args'
        if ($null -eq $a -or $a.Value -isnot [System.Array]) { return $false }
        foreach ($x in $a.Value) {
            if ($x -is [string] -and $x -match '[\\/]ask-bell[\\/]bell\.ps1$') { return $true }
        }
        return $false
    }

    function New-Handler([string]$BellPath) {
        $h = New-Object PSObject
        $h.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'type', 'command'))
        $h.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'command', 'powershell.exe'))
        [object[]]$argv = '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $BellPath
        $h.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'args', $argv))
        $h.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'timeout', 10))
        $h.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'async', $true))
        return $h
    }

    function New-Group([string]$Matcher, $Handler) {
        $g = New-Object PSObject
        $g.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'matcher', $Matcher))
        [object[]]$list = @($Handler)
        $g.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'hooks', $list))
        return $g
    }

    function Read-Settings([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return (New-Object PSObject) }
        $text = Read-Utf8 $Path
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        if ($text.Trim().Length -eq 0) { return (New-Object PSObject) }
        # PowerShell 7 unrolls a one-element root array, so check the text itself.
        if ($text.TrimStart()[0] -ne '{') { throw "the root of $Path is not a JSON object; file left untouched" }
        # PowerShell 7 also accepts comments and trailing commas, which a rewrite would drop.
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $strict = $true
            try { Add-Type -AssemblyName System.Text.Json } catch { $strict = $false }
            if ($strict) {
                try { ([System.Text.Json.JsonDocument]::Parse($text)).Dispose() }
                catch { throw "invalid JSON in ${Path} (comments and trailing commas are not allowed); file left untouched" }
            }
        }
        try { $root = ConvertFrom-Json -InputObject $text }
        catch { throw "invalid JSON in ${Path}: $($_.Exception.Message)" }
        if ($root -isnot $PSObj) { throw "the root of $Path is not a JSON object; file left untouched" }
        return $root
    }

    function To-Json($Root) { return (ConvertTo-Json -InputObject $Root -Depth 100) }

    # Removes our handlers in place and returns how many. A matcher group or
    # an event list is removed only when it became empty because of that.
    function Remove-Ours($Root) {
        $n = 0
        $hp = Get-Exact $Root 'hooks'
        if ($null -eq $hp -or $hp.Value -isnot $PSObj) { return 0 }
        $hooks = $hp.Value
        foreach ($ep in @($hooks.PSObject.Properties)) {
            if ($ep.Value -isnot [System.Array]) { continue }
            $before = $n
            $keep = New-Object System.Collections.Generic.List[object]
            foreach ($g in $ep.Value) {
                $gh = $null
                if ($g -is $PSObj) { $gh = Get-Exact $g 'hooks' }
                if ($null -eq $gh -or $gh.Value -isnot [System.Array]) { $keep.Add($g); continue }
                $rest = New-Object System.Collections.Generic.List[object]
                foreach ($h in $gh.Value) { if (Test-Ours $h) { $n++ } else { $rest.Add($h) } }
                if ($rest.Count -eq $gh.Value.Count) { $keep.Add($g); continue }
                if ($rest.Count -gt 0) { $gh.Value = $rest.ToArray(); $keep.Add($g) }
            }
            if ($n -gt $before) {
                if ($keep.Count -eq 0) { $hooks.PSObject.Properties.Remove($ep.Name) }
                else { $ep.Value = $keep.ToArray() }
            }
        }
        if ($n -gt 0 -and @($hooks.PSObject.Properties).Count -eq 0) { $Root.PSObject.Properties.Remove($hp.Name) }
        return $n
    }

    # True when exactly our two entries exist, once each, in the expected shape.
    function Test-Installed($Root, [string]$BellPath) {
        $hp = Get-Exact $Root 'hooks'
        if ($null -eq $hp -or $hp.Value -isnot $PSObj) { return $false }
        $want = ConvertTo-Json -InputObject (New-Handler $BellPath) -Compress -Depth 5
        $total = 0
        $found = @{}
        foreach ($ep in @($hp.Value.PSObject.Properties)) {
            if ($ep.Value -isnot [System.Array]) { continue }
            foreach ($g in $ep.Value) {
                if ($g -isnot $PSObj) { continue }
                $gh = Get-Exact $g 'hooks'
                if ($null -eq $gh -or $gh.Value -isnot [System.Array]) { continue }
                $gm = Get-Exact $g 'matcher'
                foreach ($h in $gh.Value) {
                    if (-not (Test-Ours $h)) { continue }
                    $total++
                    $same = (ConvertTo-Json -InputObject $h -Compress -Depth 5) -ceq $want
                    if ($same -and $null -ne $gm -and $gh.Value.Count -eq 1) {
                        $key = $ep.Name + '|' + $gm.Value
                        if ($found.ContainsKey($key)) { $found[$key]++ } else { $found[$key] = 1 }
                    }
                }
            }
        }
        if ($total -ne $Events.Count) { return $false }
        foreach ($e in $Events) {
            $key = $e.Event + '|' + $e.Matcher
            if (-not $found.ContainsKey($key) -or $found[$key] -ne 1) { return $false }
        }
        return $true
    }

    function Add-Ours($Root, [string]$BellPath) {
        if (Test-Installed $Root $BellPath) { return $false }
        if (Test-CaseClash $Root 'hooks') { throw '"hooks" is spelled in another letter case; fix it first, file left untouched' }
        $hp = Get-Exact $Root 'hooks'
        if ($null -ne $hp -and $hp.Value -isnot $PSObj) { throw '"hooks" is not an object; file left untouched' }
        foreach ($e in $Events) {
            if ($null -ne $hp) {
                if (Test-CaseClash $hp.Value $e.Event) { throw "`"hooks.$($e.Event)`" is spelled in another letter case; fix it first, file left untouched" }
                $ep = Get-Exact $hp.Value $e.Event
                if ($null -ne $ep -and $ep.Value -isnot [System.Array]) { throw "`"hooks.$($e.Event)`" is not an array; file left untouched" }
            }
        }
        $null = Remove-Ours $Root   # drop stale entries, e.g. from an older path
        $hp = Get-Exact $Root 'hooks'
        if ($null -eq $hp) {
            $Root.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty 'hooks', (New-Object PSObject)))
            $hp = $Root.PSObject.Properties['hooks']
        }
        foreach ($e in $Events) {
            $group = New-Group $e.Matcher (New-Handler $BellPath)
            $ep = Get-Exact $hp.Value $e.Event
            if ($null -eq $ep) {
                [object[]]$fresh = @($group)
                $hp.Value.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty $e.Event, $fresh))
            } else {
                $grow = New-Object System.Collections.Generic.List[object]
                foreach ($x in $ep.Value) { $grow.Add($x) }
                $grow.Add($group)
                $ep.Value = $grow.ToArray()
            }
        }
        return $true
    }

    # Everything except our entries, ignoring empty hook containers, as compact JSON.
    function Get-Rest([string]$Text) {
        if ($Text.Trim().Length -eq 0) { $r = New-Object PSObject } else { $r = ConvertFrom-Json -InputObject $Text }
        $null = Remove-Ours $r
        $hp = Get-Exact $r 'hooks'
        if ($null -ne $hp -and $hp.Value -is $PSObj) {
            foreach ($ep in @($hp.Value.PSObject.Properties)) {
                if ($ep.Value -is [System.Array] -and $ep.Value.Count -eq 0) { $hp.Value.PSObject.Properties.Remove($ep.Name) }
            }
            if (@($hp.Value.PSObject.Properties).Count -eq 0) { $r.PSObject.Properties.Remove($hp.Name) }
        }
        return (ConvertTo-Json -InputObject $r -Compress -Depth 100)
    }

    function Assert-Result([string]$BeforeText, [string]$AfterPath, [bool]$Adding, [string]$BellPath) {
        $after = Read-Utf8 $AfterPath
        $root = ConvertFrom-Json -InputObject $after
        if ($root -isnot $PSObj) { throw 'result root is not an object' }
        if ((Get-Rest $BeforeText) -cne (Get-Rest $after)) { throw 'content outside our hooks changed' }
        if ($Adding -and -not (Test-Installed $root $BellPath)) { throw 'hooks missing after install' }
        if (-not $Adding) {
            $copy = ConvertFrom-Json -InputObject $after
            if ((Remove-Ours $copy) -ne 0) { throw 'hooks still present after uninstall' }
        }
    }

    # Follow symbolic links to the real file, so a linked settings.json stays a link.
    function Resolve-Link([string]$Path) {
        for ($i = 0; $i -lt 40; $i++) {
            if (-not (Test-Path -LiteralPath $Path)) { break }
            $item = Get-Item -LiteralPath $Path -Force
            if ($item.LinkType -ne 'SymbolicLink') { break }
            $next = @($item.Target)[0]
            if (-not [System.IO.Path]::IsPathRooted($next)) { $next = Join-Path (Split-Path -Parent $Path) $next }
            $Path = $next
        }
        return $Path
    }

    function Write-Utf8([string]$Path, [string]$Text) {
        [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
    }

    function Remove-Bell([string]$BellPath) {
        if (Test-Path -LiteralPath $BellPath) { Remove-Item -LiteralPath $BellPath -Force }
        $dir = Split-Path -Parent $BellPath
        if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force }
    }

    $onWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if (-not $onWindows -and $env:ASK_BELL_ANY_OS -ne '1') {
        throw 'ask-bell: this installer is for Windows. On macOS run install.sh (see README).'
    }

    if ($Target) { $settingsPath = $Target }
    elseif ($env:CLAUDE_CONFIG_DIR) { $settingsPath = Join-Path $env:CLAUDE_CONFIG_DIR 'settings.json' }
    else { $settingsPath = Join-Path $HOME (Join-Path '.claude' 'settings.json') }
    $settingsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($settingsPath)
    $configDir = Split-Path -Parent $settingsPath
    $bellPath = (Join-Path $configDir (Join-Path 'ask-bell' 'bell.ps1')).Replace('\', '/')
    $real = Resolve-Link $settingsPath

    if ((Test-Path -LiteralPath $real) -and (Test-Path -LiteralPath $real -PathType Container)) {
        throw "ask-bell: not a file: $real"
    }
    if ($Remove -and -not (Test-Path -LiteralPath $real)) {
        Remove-Bell $bellPath
        Say "Not installed (no settings file): $settingsPath"
        return
    }

    $tmp = "$real.ask-bell-tmp-$PID"
    $backup = ''
    try {
        $beforeText = ''
        if (Test-Path -LiteralPath $real) { $beforeText = Read-Utf8 $real }
        $root = Read-Settings $real

        if ($Remove) { $changed = (Remove-Ours $root) -gt 0 }
        else { $changed = Add-Ours $root $bellPath }

        if (-not $Remove) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bellPath)
            Write-Utf8 $bellPath $BellScript
        }

        if (-not $changed) {
            if ($Remove) {
                Remove-Bell $bellPath
                Say "Not installed, nothing changed: $settingsPath"
            } else {
                Say "Already installed, nothing changed: $settingsPath"
            }
            return
        }

        if (Test-Path -LiteralPath $real) {
            $backup = "$real.ask-bell-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID"
            Copy-Item -LiteralPath $real -Destination $backup -Force
        } else {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $real)
        }

        $outText = (To-Json $root) + "`n"
        Write-Utf8 $tmp $outText
        Assert-Result $beforeText $tmp (-not $Remove) $bellPath

        # Someone (Claude Code itself, a second run) wrote the file meanwhile: do not clobber it.
        $nowText = ''
        if (Test-Path -LiteralPath $real) { $nowText = Read-Utf8 $real }
        if ($nowText -cne $beforeText) { throw "settings changed while installing, run the command again: $real" }
        if (Test-Path -LiteralPath $real) { [System.IO.File]::Replace($tmp, $real, [NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $real) }

        try { Assert-Result $beforeText $real (-not $Remove) $bellPath }
        catch {
            $why = $_.Exception.Message
            $keep = $backup
            $backup = ''
            # restore only what we wrote; a newer save by Claude Code or an editor is left alone
            $nowText = $null
            try { $nowText = [System.IO.File]::ReadAllText($real) } catch {}
            if ($nowText -cne $outText) { throw "another program changed the settings right after this run; nothing was undone, run the command again" }
            if ($keep) { Copy-Item -LiteralPath $keep -Destination $real -Force } else { Remove-Item -LiteralPath $real -Force }
            throw "final check failed, previous settings restored: $why"
        }

        if ($Remove) {
            Remove-Bell $bellPath
            Say "Uninstalled: $settingsPath"
        } else {
            Say "Installed: $settingsPath"
            Say "Hook script: $bellPath"
        }
        if ($backup) { Say "Backup of the previous file: $backup" }
        if (-not $Remove) { Say 'Open Claude Code sessions pick this up within seconds; if /hooks does not list it, restart the session.' }
        $backup = ''
    }
    catch {
        if ($backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force }
        throw "ask-bell: $($_.Exception.Message) (settings left as they were: $real)"
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
} ([bool]$AskBellUninstall) ([string]$AskBellSettings)
# "irm | iex" runs in the caller's scope: leave nothing behind there.
Remove-Variable -Name AskBellUninstall, AskBellSettings -ErrorAction SilentlyContinue
