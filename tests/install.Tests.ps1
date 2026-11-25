# Tests for install.ps1 and the bell.ps1 hook it writes (Windows).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\install.Tests.ps1   # Windows PowerShell 5.1
#   pwsh -NoProfile -File tests\install.Tests.ps1                                 # PowerShell 7
#
# Works in a throwaway folder with its own CLAUDE_CONFIG_DIR; never touches
# your real ~\.claude and plays no sound (the hook runs in dry-run mode).
# Prints one line per check and throws at the end if any check failed.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repo = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repo 'install.ps1'
$script:passed = 0
$script:failed = 0

function Check([string]$Name, [bool]$Ok, [string]$Info = '') {
    if ($Ok) { $script:passed++; Write-Host "ok   $Name" }
    else { $script:failed++; Write-Host "FAIL $Name $Info" }
}

function Read-Json([string]$Path) { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))) }

function Get-Ours($Data) {
    $out = New-Object System.Collections.Generic.List[object]
    $hp = $Data.PSObject.Properties['hooks']
    if ($null -eq $hp) { return , $out.ToArray() }
    foreach ($ep in $hp.Value.PSObject.Properties) {
        foreach ($g in $ep.Value) {
            foreach ($h in $g.hooks) {
                $a = $h.PSObject.Properties['args']
                if ($null -ne $a -and (@($a.Value)[-1] -match 'ask-bell/bell\.ps1$')) {
                    $out.Add([pscustomobject]@{ Event = $ep.Name; Matcher = $g.matcher; Handler = $h })
                }
            }
        }
    }
    return , $out.ToArray()
}

# The file without our entries, as compact JSON, for "nothing else changed".
function Get-Rest([string]$Path) {
    $d = Read-Json $Path
    $hp = $d.PSObject.Properties['hooks']
    if ($null -ne $hp) {
        foreach ($ep in @($hp.Value.PSObject.Properties)) {
            $keep = @($ep.Value | Where-Object { -not (@($_.hooks | Where-Object { $_.PSObject.Properties['args'] -and (@($_.args)[-1] -match 'ask-bell/bell\.ps1$') }).Count) })
            if ($keep.Count -eq 0) { $hp.Value.PSObject.Properties.Remove($ep.Name) } else { $ep.Value = [object[]]$keep }
        }
        if (@($hp.Value.PSObject.Properties).Count -eq 0) { $d.PSObject.Properties.Remove('hooks') }
    }
    return (ConvertTo-Json -InputObject $d -Compress -Depth 100)
}

# Named parameters go in a hashtable: an array splat passes '-Settings' as a plain positional
# string, so the installer took '-Settings' itself as the path (found on Windows 23.11).
function Invoke-Installer([hashtable]$Arguments) {
    try { & $installer @Arguments | Out-Null; return $true } catch { return $false }
}

function Get-HomeState { return (@(Get-ChildItem -LiteralPath $HOME -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) | Sort-Object) -join '|' }

$other = @'
{
  "permissions": { "allow": ["Bash(ls:*)"], "deny": [] },
  "env": { "FOO": "bar \u00e7\u015f\u011f <&>" },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "echo pre && true" }] },
      { "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "other-tool" }] }
    ],
    "Stop": [{ "hooks": [{ "type": "command", "command": "echo stop" }] }]
  },
  "model": "opus"
}
'@

$question = '{"hook_event_name":"PreToolUse","cwd":"C:\\code\\my-app","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Database","question":"Which database should we use?"}]}}'
$permission = '{"hook_event_name":"Notification","cwd":"C:\\code\\my-app\\","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ask-bell-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp
$savedConfig = $env:CLAUDE_CONFIG_DIR
$homeBefore = Get-HomeState
$env:ASK_BELL_ANY_OS = '1'
Push-Location -LiteralPath $tmp   # a relative path that slips through lands in the temp folder, not in the caller's folder
try {
    # fresh install
    $dir = Join-Path $tmp 'fresh dir'
    $s = Join-Path $dir 'settings.json'
    Check 'fresh install runs' (Invoke-Installer @{ Settings = $s })
    Check 'named -Settings path is the one written' ((Test-Path -LiteralPath $s) -and -not (Test-Path -LiteralPath (Join-Path $tmp '-Settings')))
    $d = Read-Json $s
    $ours = Get-Ours $d
    Check 'fresh install adds two entries' ($ours.Count -eq 2)
    $pairs = ($ours | ForEach-Object { $_.Event + '|' + $_.Matcher } | Sort-Object) -join ','
    Check 'entries are question + permission' ($pairs -eq 'Notification|permission_prompt,PreToolUse|AskUserQuestion') $pairs
    $h = $ours[0].Handler
    Check 'handler is exec form' ($h.command -eq 'powershell.exe' -and @($h.args).Count -eq 6 -and $h.timeout -eq 10 -and $h.async -eq $true)
    Check 'bell.ps1 written' (Test-Path -LiteralPath (Join-Path $dir 'ask-bell\bell.ps1'))

    # other content kept, second run changes nothing, uninstall restores
    $dir = Join-Path $tmp 'merge'
    $null = New-Item -ItemType Directory -Path $dir
    $s = Join-Path $dir 'settings.json'
    [IO.File]::WriteAllText($s, $other)
    $orig = Join-Path $tmp 'orig.json'
    [IO.File]::WriteAllText($orig, $other)
    Check 'merge install runs' (Invoke-Installer @{ Settings = $s })
    Check 'merge adds two entries' ((Get-Ours (Read-Json $s)).Count -eq 2)
    Check 'nothing else changed' ((Get-Rest $s) -ceq (Get-Rest $orig))
    $after = [IO.File]::ReadAllText($s)
    $nBackups = @(Get-ChildItem -LiteralPath $dir -Filter '*.ask-bell-backup-*').Count
    Check 'second run succeeds' (Invoke-Installer @{ Settings = $s })
    Check 'second run leaves file identical' ([IO.File]::ReadAllText($s) -ceq $after)
    Check 'second run makes no backup' (@(Get-ChildItem -LiteralPath $dir -Filter '*.ask-bell-backup-*').Count -eq $nBackups)
    Check 'uninstall runs' (Invoke-Installer @{ Uninstall = $true; Settings = $s })
    Check 'uninstall removes our entries' ((Get-Ours (Read-Json $s)).Count -eq 0)
    Check 'uninstall restores the rest' ((Get-Rest $s) -ceq (Get-Rest $orig))
    Check 'uninstall removes bell folder' (-not (Test-Path -LiteralPath (Join-Path $dir 'ask-bell')))
    Check 'no temp files left' (@(Get-ChildItem -LiteralPath $dir -Filter '*.ask-bell-tmp-*').Count -eq 0)
    $text = [IO.File]::ReadAllText($s)
    Check 'uninstall twice is a no-op' ((Invoke-Installer @{ Uninstall = $true; Settings = $s }) -and [IO.File]::ReadAllText($s) -ceq $text)

    # written without a byte order mark
    $bytes = [IO.File]::ReadAllBytes($s)
    Check 'no BOM written' (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))

    # bad files stay untouched
    $bad = @{
        'invalid' = '{"hooks": '
        'array root' = '[1, 2]'
        'one-element array root' = '[{"a": 1}]'
        'hooks not object' = '{"hooks": []}'
        'event not array' = '{"hooks": {"PreToolUse": {}}}'
    }
    foreach ($k in $bad.Keys) {
        $dir = Join-Path $tmp ('bad-' + ($k -replace '\W', '-'))
        $null = New-Item -ItemType Directory -Path $dir
        $s = Join-Path $dir 'settings.json'
        [IO.File]::WriteAllText($s, $bad[$k])
        $ok = Invoke-Installer @{ Settings = $s }
        $files = @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ne 'ask-bell' }).Count
        Check "bad file refused: $k" ((-not $ok) -and [IO.File]::ReadAllText($s) -ceq $bad[$k] -and $files -eq 1)
    }

    # regressions from the adversarial review (23.11)
    $dir = Join-Path $tmp 'case'
    $null = New-Item -ItemType Directory -Path $dir
    $s = Join-Path $dir 'settings.json'
    $caseText = '{"hooks": {"pretooluse": []}}'
    [IO.File]::WriteAllText($s, $caseText)
    Check 'event name in another letter case is refused' ((-not (Invoke-Installer @{ Settings = $s })) -and [IO.File]::ReadAllText($s) -ceq $caseText)

    $dir = Join-Path $tmp 'cp1254'
    $null = New-Item -ItemType Directory -Path $dir
    $s = Join-Path $dir 'settings.json'
    [byte[]]$raw = 0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFD, 0x22, 0x7D   # {"a":"<cp1254 dotless i>"}
    [IO.File]::WriteAllBytes($s, $raw)
    $ok = Invoke-Installer @{ Settings = $s }
    $same = [Convert]::ToBase64String([IO.File]::ReadAllBytes($s)) -eq [Convert]::ToBase64String($raw)
    Check 'file that is not UTF-8 is refused and kept' ((-not $ok) -and $same)

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $dir = Join-Path $tmp 'comments'
        $null = New-Item -ItemType Directory -Path $dir
        $s = Join-Path $dir 'settings.json'
        $commented = "{`n  // keep me`n  `"model`": `"opus`",`n}`n"
        [IO.File]::WriteAllText($s, $commented)
        Check 'comments and trailing commas are refused (PowerShell 7)' ((-not (Invoke-Installer @{ Settings = $s })) -and [IO.File]::ReadAllText($s) -ceq $commented)
    }

    $dir = Join-Path $tmp 'backup-name'
    $null = New-Item -ItemType Directory -Path $dir
    $s = Join-Path $dir 'settings.json'
    [IO.File]::WriteAllText($s, $other)
    $null = Invoke-Installer @{ Settings = $s }
    $b = @(Get-ChildItem -LiteralPath $dir -Filter '*.ask-bell-backup-*')
    Check 'backup name carries the process id' ($b.Count -eq 1 -and $b[0].Name -match '\.ask-bell-backup-\d{8}-\d{6}-\d+$')

    $dir = Join-Path $tmp 'not-ours'
    $null = New-Item -ItemType Directory -Path $dir
    $s = Join-Path $dir 'settings.json'
    $notOurs = '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "pwsh", "args": ["-File", "C:/tools/ask-bell/bell.ps1"]}]}]}}'
    [IO.File]::WriteAllText($s, $notOurs)
    $null = Invoke-Installer @{ Settings = $s }
    $null = Invoke-Installer @{ Uninstall = $true; Settings = $s }
    $kept = ConvertTo-Json -InputObject (Read-Json $s) -Compress -Depth 100
    Check "another program's hook with a similar path is kept" ($kept -ceq (ConvertTo-Json -InputObject (ConvertFrom-Json -InputObject $notOurs) -Compress -Depth 100)) $kept

    # the "irm | iex" path and the scriptblock uninstall path
    $dir = Join-Path $tmp 'iex'
    $env:CLAUDE_CONFIG_DIR = $dir
    $code = [IO.File]::ReadAllText($installer)
    try { Invoke-Expression $code | Out-Null; $ok = $true } catch { $ok = $false; Write-Host $_ }
    Check 'iex install works' ($ok -and (Get-Ours (Read-Json (Join-Path $dir 'settings.json'))).Count -eq 2)
    Check 'iex leaves no variables behind' ($null -eq (Get-Variable -Name AskBellUninstall, AskBellSettings -ErrorAction SilentlyContinue))
    try { & ([scriptblock]::Create($code)) -Uninstall | Out-Null; $ok = $true } catch { $ok = $false; Write-Host $_ }
    Check 'scriptblock uninstall works' ($ok -and (Get-Ours (Read-Json (Join-Path $dir 'settings.json'))).Count -eq 0)
    $env:CLAUDE_CONFIG_DIR = $savedConfig

    # the hook, run the way Claude Code runs it (exec form, JSON on stdin)
    $dir = Join-Path $tmp 'hook'
    $s = Join-Path $dir 'settings.json'
    $null = Invoke-Installer @{ Settings = $s }
    $ours = Get-Ours (Read-Json $s)
    $env:ASK_BELL_DRY_RUN = '1'
    foreach ($case in @(
            @{ Event = 'PreToolUse'; Json = $question; Want = 'Claude Code | my-app is asking a question: Database: Which database should we use?' },
            @{ Event = 'Notification'; Json = $permission; Want = 'Claude Code | my-app is waiting for your permission: Claude needs your permission to use Bash' })) {
        $h = ($ours | Where-Object { $_.Event -eq $case.Event }).Handler
        $argv = @($h.args)
        $out = ($case.Json | & $h.command @argv) -join "`n"
        Check "hook text for $($case.Event)" ($LASTEXITCODE -eq 0 -and $out.Trim() -eq $case.Want) $out
    }
    foreach ($junk in @('', 'not json', '[]', 'null', '{"tool_name": 5, "cwd": []}')) {
        $out = ($junk | & $h.command @argv) -join "`n"
        Check "hook survives input '$junk'" ($LASTEXITCODE -eq 0 -and $out.StartsWith('Claude Code | ')) $out
    }
    Remove-Item Env:\ASK_BELL_DRY_RUN
}
finally {
    Pop-Location
    $env:CLAUDE_CONFIG_DIR = $savedConfig
    Remove-Item Env:\ASK_BELL_ANY_OS -ErrorAction SilentlyContinue
    Remove-Item Env:\ASK_BELL_DRY_RUN -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$homeAfter = Get-HomeState
Check 'nothing written to the home folder' ($homeAfter -ceq $homeBefore) "before: $homeBefore | after: $homeAfter"
Write-Host "$($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { throw "$($script:failed) check(s) failed" }
