# Ask Bell

A bell for Claude Code. It plays a sound and shows a notification when Claude asks you a question or waits for your permission, so you can look away while it works.

Works on macOS and Windows, in every Claude Code session that reads your user settings: the terminal, the IDE extensions and the desktop app.

## Install

**macOS** (Terminal):

```sh
curl -fsSL https://raw.githubusercontent.com/metincanaktas/ask-bell/main/install.sh | sh
```

**Windows** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/metincanaktas/ask-bell/main/install.ps1 | iex
```

That's it. Open Claude Code sessions pick the change up within a few seconds; if `/hooks` does not list it, restart the session. To try it, ask Claude: *"Ask me a question with the AskUserQuestion tool."*

Prefer to read the code first? Clone this repository and run `sh install.sh` on macOS, or `powershell -ExecutionPolicy Bypass -File .\install.ps1` on Windows. Each installer is one file.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/metincanaktas/ask-bell/main/install.sh | sh -s -- --uninstall
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/metincanaktas/ask-bell/main/install.ps1))) -Uninstall
```

From a clone: `sh install.sh --uninstall`, or `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall`.

## What it changes

Two things, both inside your Claude Code config folder (`$CLAUDE_CONFIG_DIR`, or `~/.claude`):

1. It writes the hook script: `ask-bell/bell.sh` on macOS, `ask-bell\bell.ps1` on Windows.
2. It adds two entries to `settings.json`:
   - `PreToolUse` with matcher `AskUserQuestion`: rings right before Claude shows you a question.
   - `Notification` with matcher `permission_prompt`: rings when a permission prompt is waiting for you.

Nothing else in `settings.json` is touched: other hooks, permissions and keys stay as they are. Before writing, the installer saves a copy next to the file (`settings.json.ask-bell-backup-<time>`), checks the result and puts the copy back if anything looks wrong. A file that is not valid JSON is left alone. Running it twice changes nothing. Uninstall removes only these two entries and the hook script.

On macOS the file keeps its indentation, line endings and byte order mark, so for a normally formatted file (one value per line, as Claude Code writes it) install followed by uninstall gives back the same bytes. A file written compactly on one line is spread over several lines, `\uXXXX` escapes become the characters themselves, extra blank lines and empty `{}` or `[]` containers under `hooks` are dropped, and the file is read as ordinary JSON: duplicate keys keep the last value, numbers beyond 15 digits lose precision and keys that look like numbers move to the top. None of this changes how Claude Code reads the file for normal settings, and the backup keeps your original bytes. On Windows the content stays the same but PowerShell rewrites the formatting (spacing and indentation).

Both hooks run with `"async": true`, so Claude Code never waits for the bell.

macOS entry:

```json
{ "type": "command", "command": "/bin/sh '<config>/ask-bell/bell.sh' # ask-bell", "timeout": 10, "async": true }
```

Windows entry (exec form, no shell in between):

```json
{ "type": "command", "command": "powershell.exe",
  "args": ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "<config>/ask-bell/bell.ps1"],
  "timeout": 10, "async": true }
```

## Requirements

- **macOS:** nothing to install. It uses `afplay` and `osascript`, which ship with macOS.
- **Windows:** nothing to install. It uses Windows PowerShell 5.1, which ships with Windows 10 and 11. The installer runs in Windows PowerShell or PowerShell 7. Claude Code 2.1.139 or newer (the hook uses the `args` field).

## Settings

Set these in the `"env"` block of `settings.json`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `ASK_BELL_SOUND` | macOS: `/System/Library/Sounds/Glass.aiff` · Windows: `Windows Notify System Generic.wav` | Sound file to play |
| `ASK_BELL_DRY_RUN` | unset | `1` prints the notification text instead of ringing |

Test the hook by hand:

```sh
sh ~/.claude/ask-bell/bell.sh --dry-run < examples/question.json
```

```powershell
Get-Content examples\question.json | powershell -NoProfile -ExecutionPolicy Bypass -File $HOME\.claude\ask-bell\bell.ps1 -DryRun
```

## Troubleshooting

- **No sound on macOS:** try `afplay /System/Library/Sounds/Glass.aiff`, then check the volume and output device.
- **No notification on macOS:** notifications from `osascript` appear as **Script Editor**. Run `osascript -e 'display notification "test"'` once, then turn on **System Settings → Notifications → Script Editor → Allow Notifications**. Focus modes hide banners; the sound still plays.
- **No notification on Windows:** the toast appears under **Windows PowerShell**. Check **Settings → System → Notifications** and Focus assist.
- **Nothing happens:** run `/hooks` in Claude Code and look for the two entries. If they are missing, restart the session. Make sure `"disableAllHooks"` is not `true`.
- **The permission bell comes late:** Claude Code sends `permission_prompt` after a prompt has waited a few seconds.

## Development

```sh
python3 -I -B -m unittest discover -s tests -v                    # macOS: installer and hook
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\install.Tests.ps1   # Windows PowerShell 5.1
pwsh -NoProfile -File tests\install.Tests.ps1                                 # PowerShell 7
```

The tests work in throwaway folders, never touch your real settings and play no sound. CI runs both on every push.

## License

MIT. See [LICENSE](LICENSE). The sounds are the system sounds that ship with macOS and Windows; none are included here.
