"""Tests for install.sh and the bell.sh hook it writes (macOS).

Run from the repo root:  python3 -I -m unittest discover -s tests -v
Every test works in a throwaway folder with its own HOME and
CLAUDE_CONFIG_DIR; nothing touches your real ~/.claude and no sound plays
(afplay and osascript are replaced by recording stubs where a test rings).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.path.join(ROOT, "install.sh")
MACOS = sys.platform == "darwin"

OTHER = {
    "permissions": {"allow": ["Bash(ls:*)"], "deny": []},
    "env": {"FOO": "bar \u00e7\u015f\u011f"},
    "hooks": {
        "PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre && true"}]},
            {"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": "other-tool"}]},
        ],
        "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}],
    },
    "model": "opus",
}

QUESTION = {
    "hook_event_name": "PreToolUse",
    "cwd": "/home/someone/code/my-app",
    "tool_name": "AskUserQuestion",
    "tool_input": {"questions": [{"header": "Database", "question": "Which database should we use?",
                                  "options": [{"label": "Postgres"}, {"label": "SQLite"}]}]},
}
PERMISSION = {
    "hook_event_name": "Notification",
    "cwd": "/home/someone/code/my-app/",
    "notification_type": "permission_prompt",
    "message": "Claude needs your permission to use Bash",
}


def dump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False)


@unittest.skipUnless(MACOS, "install.sh is macOS only")
class InstallSh(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ask-bell-test-")
        self.home = os.path.join(self.tmp, "home")
        self.cfg = os.path.join(self.tmp, "config dir")
        os.makedirs(self.home)
        self.settings = os.path.join(self.cfg, "settings.json")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def env(self, **extra):
        e = {"HOME": self.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CLAUDE_CONFIG_DIR": self.cfg,
             "TMPDIR": self.tmp + "/"}
        e.update(extra)
        return e

    def run_install(self, *args, stdin_script=False, env=None):
        e = env or self.env()
        if stdin_script:  # the "curl ... | sh" path: the script arrives on stdin
            with open(INSTALL, "rb") as f:
                return subprocess.run(["/bin/sh", "-s", "--", *args], stdin=f, env=e,
                                      capture_output=True, text=True, timeout=60)
        return subprocess.run(["/bin/sh", INSTALL, *args], env=e, capture_output=True, text=True, timeout=60)

    def write(self, text):
        os.makedirs(self.cfg, exist_ok=True)
        with open(self.settings, "w", encoding="utf-8") as f:
            f.write(text)

    def read(self):
        with open(self.settings, encoding="utf-8") as f:
            return f.read()

    def ours(self, data):
        out = []
        for event, groups in data.get("hooks", {}).items():
            for g in groups:
                for h in g.get("hooks", []):
                    if "# ask-bell" in h.get("command", ""):
                        out.append((event, g.get("matcher"), h))
        return out

    def backups(self):
        return [n for n in os.listdir(self.cfg) if ".ask-bell-backup-" in n]

    def leftovers(self):
        return [n for n in os.listdir(self.cfg) if ".ask-bell-tmp-" in n]

    # --- cut downloads, signals, odd paths ---

    def test_download_cut_near_the_end_never_acts(self):
        # "curl | sh -s -- --uninstall" cut right after a bare "main" used to install
        with open(INSTALL, "rb") as f:
            script = f.read().rstrip(b"\n")
        for cut in range(len(script) - 40, len(script)):
            r = subprocess.run(["/bin/sh", "-s", "--", "--uninstall"], input=script[:cut], env=self.env(),
                               capture_output=True, timeout=60)
            self.assertFalse(os.path.exists(self.settings), (cut, r.stdout))

    def test_signal_right_after_the_swap_keeps_the_backup(self):
        original = '{\n  "model": "x"\n}\n'
        self.write(original)
        stub = os.path.join(self.tmp, "stub")
        os.makedirs(stub)
        with open(os.path.join(stub, "mv"), "w") as f:
            f.write('#!/bin/sh\n/bin/mv "$@" || exit\ncase "$*" in *settings.json) kill -TERM $PPID ;; esac\n')
        os.chmod(os.path.join(stub, "mv"), 0o755)
        r = self.run_install(env=self.env(PATH=stub + ":/usr/bin:/bin:/usr/sbin:/sbin"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ask-bell", self.read())
        self.assertEqual(len(self.backups()), 1)
        with open(os.path.join(self.cfg, self.backups()[0]), encoding="utf-8") as f:
            self.assertEqual(f.read(), original)

    def test_empty_path_and_folder_path_are_refused(self):
        folder = os.path.join(self.tmp, "newdir") + "/"
        for arg in ("", folder):
            r = self.run_install(arg)
            self.assertNotEqual(r.returncode, 0, repr(arg))
            self.assertFalse(os.path.exists(self.settings), repr(arg))
            self.assertFalse(os.path.exists(folder.rstrip("/")), repr(arg))
            self.assertFalse(os.path.exists(os.path.join(self.tmp, "ask-bell")), repr(arg))

    # --- install / uninstall ---

    def test_fresh_install_creates_settings_and_hook(self):
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(self.read())
        got = self.ours(data)
        self.assertEqual(sorted((e, m) for e, m, _ in got),
                         [("Notification", "permission_prompt"), ("PreToolUse", "AskUserQuestion")])
        for _, _, h in got:
            self.assertEqual(h["timeout"], 10)
            self.assertIs(h["async"], True)
            self.assertIn(os.path.join(self.cfg, "ask-bell", "bell.sh"), h["command"])
        self.assertTrue(os.path.isfile(os.path.join(self.cfg, "ask-bell", "bell.sh")))
        self.assertEqual(self.backups(), [])

    def test_keeps_everything_else(self):
        self.write(dump(OTHER) + "\n")
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(self.read())
        self.assertEqual(len(self.ours(data)), 2)
        for event, groups in list(data["hooks"].items()):
            data["hooks"][event] = [g for g in groups if not any("# ask-bell" in h.get("command", "") for h in g["hooks"])]
            if not data["hooks"][event]:
                del data["hooks"][event]
        self.assertEqual(data, OTHER)
        self.assertEqual(len(self.backups()), 1)

    def test_second_run_changes_nothing(self):
        self.write(dump(OTHER) + "\n")
        self.run_install()
        before = self.read()
        n = len(self.backups())
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Already installed", r.stdout)
        self.assertEqual(self.read(), before)
        self.assertEqual(len(self.backups()), n)

    def test_uninstall_restores_claude_code_formatted_file_byte_for_byte(self):
        for text in (dump(OTHER), dump(OTHER) + "\n", json.dumps(OTHER, indent="\t", ensure_ascii=False) + "\n"):
            with self.subTest(text=text[:20]):
                self.write(text)
                self.assertEqual(self.run_install().returncode, 0)
                r = self.run_install("--uninstall")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.read(), text)
                self.assertFalse(os.path.exists(os.path.join(self.cfg, "ask-bell")))

    def test_uninstall_of_fresh_install_leaves_empty_object(self):
        self.run_install()
        self.run_install("--uninstall")
        self.assertEqual(json.loads(self.read()), {})

    def test_uninstall_when_not_installed(self):
        self.write(dump(OTHER) + "\n")
        before = self.read()
        r = self.run_install("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Not installed", r.stdout)
        self.assertEqual(self.read(), before)
        self.assertEqual(self.backups(), [])

    def test_uninstall_without_settings_file(self):
        r = self.run_install("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.settings))

    def test_curl_pipe_sh_path(self):
        self.write(dump(OTHER) + "\n")
        r = self.run_install(stdin_script=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.ours(json.loads(self.read()))), 2)
        r = self.run_install("--uninstall", stdin_script=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read(), dump(OTHER) + "\n")

    def test_explicit_settings_path_argument(self):
        other = os.path.join(self.tmp, "elsewhere", "settings.json")
        r = self.run_install(other)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.ours(json.loads(open(other).read()))), 2)
        self.assertTrue(os.path.isfile(os.path.join(self.tmp, "elsewhere", "ask-bell", "bell.sh")))
        self.assertFalse(os.path.exists(self.settings))

    def test_moved_config_replaces_stale_entry(self):
        stale = {"hooks": {"PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [
            {"type": "command", "command": "/bin/sh '/old/place/ask-bell/bell.sh' # ask-bell", "timeout": 10, "async": True}]}]}}
        self.write(dump(stale) + "\n")
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stderr)
        got = self.ours(json.loads(self.read()))
        self.assertEqual(len(got), 2)
        self.assertTrue(all("/old/place" not in h["command"] for _, _, h in got))

    def test_bad_files_are_left_untouched(self):
        cases = {
            "invalid": '{"hooks": ',
            "array root": "[1, 2]",
            "hooks not object": '{"hooks": []}',
            "event not array": '{"hooks": {"PreToolUse": {}}}',
            "string root": '"x"',
        }
        for name, text in cases.items():
            with self.subTest(name):
                self.write(text)
                r = self.run_install()
                self.assertEqual(r.returncode, 1, name)
                self.assertIn("ask-bell:", r.stderr)
                self.assertEqual(self.read(), text)
                self.assertEqual(self.backups(), [])
                self.assertEqual(self.leftovers(), [])

    def test_empty_and_bom_files(self):
        for text in ("", "  \n", "\ufeff" + dump(OTHER) + "\n"):
            with self.subTest(text=text[:5]):
                self.write(text)
                r = self.run_install()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(len(self.ours(json.loads(self.read().lstrip("\ufeff")))), 2)
                self.run_install("--uninstall")
                for b in self.backups():
                    os.remove(os.path.join(self.cfg, b))

    def test_symlinked_settings_stay_a_link(self):
        real_dir = os.path.join(self.tmp, "dotfiles")
        os.makedirs(real_dir)
        real = os.path.join(real_dir, "settings.json")
        with open(real, "w") as f:
            f.write(dump(OTHER) + "\n")
        os.makedirs(self.cfg)
        os.symlink(real, self.settings)
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.islink(self.settings))
        self.assertEqual(len(self.ours(json.loads(open(real).read()))), 2)

    def test_file_mode_is_kept(self):
        self.write(dump(OTHER) + "\n")
        os.chmod(self.settings, 0o600)
        self.run_install()
        self.assertEqual(os.stat(self.settings).st_mode & 0o777, 0o600)

    def test_unknown_option_and_help(self):
        r = self.run_install("--bogus")
        self.assertEqual(r.returncode, 1)
        self.assertFalse(os.path.exists(self.settings))
        r = self.run_install("--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("--uninstall", r.stdout)
        self.assertFalse(os.path.exists(self.settings))

    def test_refuses_other_systems(self):
        stub = os.path.join(self.tmp, "stub")
        os.makedirs(stub)
        with open(os.path.join(stub, "uname"), "w") as f:
            f.write("#!/bin/sh\necho Linux\n")
        os.chmod(os.path.join(stub, "uname"), 0o755)
        r = self.run_install(env=self.env(PATH=stub + ":/usr/bin:/bin"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("install.ps1", r.stderr)
        self.assertFalse(os.path.exists(self.settings))

    def test_two_runs_at_once_never_corrupt_the_file(self):
        self.write(dump(OTHER) + "\n")
        procs = [subprocess.Popen(["/bin/sh", INSTALL], env=self.env(), stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True) for _ in range(4)]
        for p in procs:
            p.communicate(timeout=60)
        data = json.loads(self.read())
        self.assertEqual(len(self.ours(data)), 2)
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(self.run_install().returncode, 0)

    # --- regressions from the adversarial review (23.11) ---

    def osascript_stub(self, body):
        """An osascript on PATH that runs `body` (sh) and then the real one."""
        stub = os.path.join(self.tmp, "stub")
        os.makedirs(stub, exist_ok=True)
        with open(os.path.join(stub, "osascript"), "w") as f:
            f.write("#!/bin/sh\n" + body + "\nexec /usr/bin/osascript \"$@\"\n")
        os.chmod(os.path.join(stub, "osascript"), 0o755)
        return self.env(PATH=stub + ":/usr/bin:/bin:/usr/sbin:/sbin")

    def test_save_by_another_program_after_install_is_not_undone(self):
        # $4=check $5=add $6=before $7=after: when the final check reads the real file,
        # another program has just saved it
        for start in (None, dump(OTHER) + "\n"):
            with self.subTest(existing=start is not None):
                shutil.rmtree(self.cfg, ignore_errors=True)
                if start:
                    self.write(start)
                env = self.osascript_stub('[ "$4" = check ] && [ "$7" = "%s" ] && printf \'{"saved": "by someone else"}\\n\' > "$7"' % self.settings)
                r = self.run_install(env=env)
                self.assertEqual(r.returncode, 1)
                self.assertIn("another program changed the settings", r.stderr)
                self.assertEqual(json.loads(self.read()), {"saved": "by someone else"})

    def test_backup_name_is_unique_per_run(self):
        self.write(dump(OTHER) + "\n")
        self.run_install()
        self.assertRegex(self.backups()[0], r"\.ask-bell-backup-\d{8}-\d{6}-\d+$")

    def test_users_own_command_mentioning_the_marker_is_kept(self):
        mine = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo \"# ask-bell\" my own"}]}],
                          "PreToolUse": [{"matcher": "X", "hooks": [{"type": "command", "command": "run # ask-bell"}]}]}}
        self.write(dump(mine) + "\n")
        self.assertEqual(self.run_install().returncode, 0)
        self.assertEqual(self.run_install("--uninstall").returncode, 0)
        self.assertEqual(self.read(), dump(mine) + "\n")

    def test_private_file_stays_private_even_with_gnu_stat_first(self):
        self.write(dump(OTHER) + "\n")
        os.chmod(self.settings, 0o600)
        stub = os.path.join(self.tmp, "gnu")
        os.makedirs(stub)
        with open(os.path.join(stub, "stat"), "w") as f:
            f.write("#!/bin/sh\necho 'stat: cannot read file system information for %Lp' >&2\nexit 1\n")
        os.chmod(os.path.join(stub, "stat"), 0o755)
        log = os.path.join(self.tmp, "modes.log")
        env = self.osascript_stub('[ "$4" = check ] && [ "$7" != "%s" ] && /usr/bin/stat -f %%Lp "$7" >> "%s"' % (self.settings, log))
        env["PATH"] = stub + ":" + env["PATH"]
        r = self.run_install(env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.stat(self.settings).st_mode & 0o777, 0o600)
        self.assertEqual(open(log).read().split(), ["600"])  # the temporary copy, before chmod

    def test_refused_install_writes_no_hook_script(self):
        self.write('{"hooks": ')
        self.assertEqual(self.run_install().returncode, 1)
        self.assertFalse(os.path.exists(os.path.join(self.cfg, "ask-bell")))

    def test_interrupted_run_leaves_no_backup_or_temp(self):
        self.write(dump(OTHER) + "\n")
        env = self.osascript_stub('[ "$4" = check ] && kill -INT $PPID && sleep 1')
        r = self.run_install(env=env)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.read(), dump(OTHER) + "\n")
        self.assertEqual(self.backups(), [])
        self.assertEqual(self.leftovers(), [])

    def test_temp_file_of_a_killed_run_is_cleaned_up(self):
        self.write(dump(OTHER) + "\n")
        stale = self.settings + ".ask-bell-tmp-999999"
        with open(stale, "w") as f:
            f.write("{}")
        self.assertEqual(self.run_install().returncode, 0)
        self.assertFalse(os.path.exists(stale))

    def test_runs_under_every_login_shell(self):
        """A stranger may start the installer with zsh (macOS default), bash or dash."""
        for shell in ("/bin/zsh", "/bin/bash", "/bin/dash", "/bin/sh"):
            if not os.path.exists(shell):
                continue
            with self.subTest(shell=shell):
                shutil.rmtree(self.cfg, ignore_errors=True)
                self.write(dump(OTHER) + "\n")
                r = subprocess.run([shell, INSTALL], env=self.env(), capture_output=True, text=True, timeout=60)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(len(self.ours(json.loads(self.read()))), 2)
                r = subprocess.run([shell, INSTALL, "--uninstall"], env=self.env(), capture_output=True,
                                   text=True, timeout=60)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.read(), dump(OTHER) + "\n")

    def test_clone_command_in_readme_works_as_written(self):
        """README says './install.sh' after a clone: the file must be executable (git keeps the bit)."""
        self.assertTrue(os.access(INSTALL, os.X_OK), "install.sh is not executable: './install.sh' fails")
        self.write(dump(OTHER) + "\n")
        r = subprocess.run([INSTALL], env=self.env(), capture_output=True, text=True, timeout=60, cwd=ROOT)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_crlf_and_bom_survive_install_and_uninstall(self):
        for text in (dump(OTHER).replace("\n", "\r\n") + "\r\n", "﻿" + dump(OTHER) + "\n"):
            with self.subTest(text=repr(text[:3])):
                with open(self.settings if os.path.isdir(self.cfg) else (os.makedirs(self.cfg) or self.settings), "w", newline="", encoding="utf-8") as f:
                    f.write(text)
                self.assertEqual(self.run_install().returncode, 0)
                with open(self.settings, newline="", encoding="utf-8") as f:
                    mid = f.read()
                self.assertEqual("\r\n" in mid, "\r\n" in text)
                self.assertEqual(self.run_install("--uninstall").returncode, 0)
                with open(self.settings, newline="", encoding="utf-8") as f:
                    self.assertEqual(f.read(), text)

    # --- the hook as Claude Code runs it ---

    def hook_command(self, event):
        data = json.loads(self.read())
        return [h["command"] for e, _, h in self.ours(data) if e == event][0]

    def test_hook_text_question_and_permission(self):
        self.run_install()
        for event, payload, want in (
            ("PreToolUse", QUESTION, "Claude Code | my-app is asking a question: Database: Which database should we use?"),
            ("Notification", PERMISSION, "Claude Code | my-app is waiting for your permission: Claude needs your permission to use Bash"),
        ):
            r = subprocess.run(["/bin/sh", "-c", self.hook_command(event)], input=json.dumps(payload),
                               env=self.env(ASK_BELL_DRY_RUN="1"), capture_output=True, text=True, timeout=20)
            self.assertEqual(r.returncode, 0)
            self.assertEqual(r.stdout.strip(), want)

    def test_hook_survives_bad_input(self):
        self.run_install()
        bell = os.path.join(self.cfg, "ask-bell", "bell.sh")
        for payload in ("", "not json", "[]", "null", '{"tool_name": 5, "cwd": []}', "x" * 300000):
            with self.subTest(payload=payload[:10]):
                r = subprocess.run(["/bin/sh", bell, "--dry-run"], input=payload, env=self.env(),
                                   capture_output=True, text=True, timeout=20)
                self.assertEqual(r.returncode, 0)
                self.assertTrue(r.stdout.startswith("Claude Code | "), r.stdout)

    def test_hook_rings_in_the_background_and_returns_at_once(self):
        self.run_install()
        stub = os.path.join(self.tmp, "stub")
        log = os.path.join(self.tmp, "calls.log")
        os.makedirs(stub)
        for name in ("afplay", "osascript"):
            with open(os.path.join(stub, name), "w") as f:
                f.write('#!/bin/sh\necho "%s $1" >> "%s"\nsleep 3\n' % (name, log))
            os.chmod(os.path.join(stub, name), 0o755)
        t = time.monotonic()
        r = subprocess.run(["/bin/sh", "-c", self.hook_command("PreToolUse")], input=json.dumps(QUESTION),
                           env=self.env(PATH=stub + ":/usr/bin:/bin"), capture_output=True, text=True, timeout=20)
        took = time.monotonic() - t
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertLess(took, 1.0)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            calls = open(log).read() if os.path.exists(log) else ""
            if "afplay" in calls and "osascript" in calls:
                break
            time.sleep(0.05)
        self.assertIn("afplay /System/Library/Sounds/Glass.aiff", calls)
        self.assertIn("osascript -l", calls)

    def test_hook_reads_a_socketpair_stdin(self):
        """Node gives a child a socketpair, not a pipe, for stdio 'pipe': the payload must still be read."""
        import socket
        self.run_install()
        bell = os.path.join(self.cfg, "ask-bell", "bell.sh")
        a, b = socket.socketpair()
        p = subprocess.Popen(["/bin/sh", bell, "--dry-run"], stdin=b, stdout=subprocess.PIPE, env=self.env(),
                             text=True)
        b.close()
        a.sendall(json.dumps(QUESTION).encode())
        a.shutdown(socket.SHUT_WR)
        out, _ = p.communicate(timeout=20)
        a.close()
        self.assertEqual(out.strip(), "Claude Code | my-app is asking a question: Database: Which database should we use?")

    def test_hook_strips_control_characters_from_the_project_name(self):
        self.run_install()
        bell = os.path.join(self.cfg, "ask-bell", "bell.sh")
        payload = json.dumps({"cwd": "/a/pro\nje\u202ect", "tool_name": "AskUserQuestion"})
        r = subprocess.run(["/bin/sh", bell, "--dry-run"], input=payload, env=self.env(), capture_output=True,
                           text=True, timeout=20)
        self.assertEqual(r.stdout.count("\n"), 1)
        self.assertNotIn("\u202e", r.stdout)

    def test_hook_with_closed_stdin_and_dash_input(self):
        self.run_install()
        bell = os.path.join(self.cfg, "ask-bell", "bell.sh")
        r = subprocess.run(["/bin/sh", "-c", 'exec <&-; /bin/sh "$0" --dry-run', bell], env=self.env(),
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "Claude Code | Claude is waiting for you")
        for payload in ("-1", "--help", "-e"):
            r = subprocess.run(["/bin/sh", bell, "--dry-run"], input=payload, env=self.env(),
                               capture_output=True, text=True, timeout=10)
            self.assertEqual(r.stdout.strip(), "Claude Code | Claude is waiting for you", payload)

    def test_hook_reads_at_most_200_kb(self):
        self.run_install()
        bell = os.path.join(self.cfg, "ask-bell", "bell.sh")
        t = time.monotonic()
        r = subprocess.run(["/bin/sh", bell, "--dry-run"], input=b"x" * (60 * 1024 * 1024), env=self.env(),
                           capture_output=True, timeout=20)
        self.assertEqual(r.returncode, 0)
        self.assertLess(time.monotonic() - t, 3.0)

    def test_custom_sound_and_missing_sound(self):
        self.run_install()
        stub = os.path.join(self.tmp, "stub")
        log = os.path.join(self.tmp, "calls.log")
        os.makedirs(stub)
        for name in ("afplay", "osascript"):
            with open(os.path.join(stub, name), "w") as f:
                f.write('#!/bin/sh\necho "%s $1" >> "%s"\n' % (name, log))
            os.chmod(os.path.join(stub, name), 0o755)
        bell = os.path.join(self.cfg, "ask-bell", "bell.sh")
        for sound, want in (("/System/Library/Sounds/Ping.aiff", "Ping.aiff"), ("/nope.aiff", "Glass.aiff")):
            if os.path.exists(log):
                os.remove(log)
            subprocess.run(["/bin/sh", bell], input="{}", env=self.env(PATH=stub + ":/usr/bin:/bin", ASK_BELL_SOUND=sound),
                           capture_output=True, text=True, timeout=20)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not (os.path.exists(log) and "afplay" in open(log).read()):
                time.sleep(0.05)
            self.assertIn(want, open(log).read())


class Ps1Static(unittest.TestCase):
    """install.ps1 cannot run here; these checks guard what Windows PowerShell 5.1 needs."""

    def setUp(self):
        with open(os.path.join(ROOT, "install.ps1"), encoding="utf-8") as f:
            self.text = f.read()

    def test_ascii_only(self):
        self.assertTrue(all(ord(c) < 128 for c in self.text))

    def test_never_exits_the_caller(self):
        body = self.text.split("$BellScript = @'")[0] + self.text.split("'@", 1)[1]
        self.assertNotRegex(body, r"(?m)^\s*exit\b")

    def test_here_string_closes_once(self):
        self.assertEqual(self.text.count("@'\n"), 1)
        self.assertEqual(len([l for l in self.text.splitlines() if l == "'@"]), 1)


class RepoHygiene(unittest.TestCase):
    def test_no_personal_data(self):
        # the machine running the tests says what must not leak: its home folder, its login name and,
        # optionally, ASK_BELL_PRIVATE_WORDS (comma-separated); nothing personal is written in this file
        bad = {"/Users/", "C:\\Users\\", "@gmail", os.path.expanduser("~")}
        login = os.environ.get("USER") or os.environ.get("USERNAME") or ""
        if len(login) >= 4:
            bad.add(login)
        bad.update(w.strip() for w in os.environ.get("ASK_BELL_PRIVATE_WORDS", "").split(",") if len(w.strip()) >= 4)
        for folder, _, files in os.walk(ROOT):
            parts = os.path.relpath(folder, ROOT).split(os.sep)
            if ".git" in parts or "__pycache__" in parts:  # ".github" is scanned
                continue
            for name in files:
                path = os.path.join(folder, name)
                if path == os.path.abspath(__file__):
                    continue
                text = open(path, encoding="utf-8", errors="replace").read()
                for b in bad:
                    self.assertNotIn(b, text, path)

    def test_hidden_github_folder_is_scanned(self):
        folder = os.path.join(ROOT, ".github", "hygiene-probe-%d" % os.getpid())
        os.makedirs(folder)
        try:
            with open(os.path.join(folder, "probe.txt"), "w") as f:
                f.write("someone@gm" + "ail.com")
            with self.assertRaises(AssertionError):
                self.test_no_personal_data()
        finally:
            shutil.rmtree(folder)


class PublicCommands(unittest.TestCase):
    """A stranger copies one line: every download URL must be the public GitHub file."""

    RAW = "https://raw.githubusercontent.com/metincanaktas/ask-bell/main/"

    def read(self, name):
        with open(os.path.join(ROOT, name), encoding="utf-8") as f:
            return f.read()

    def test_every_download_url_is_the_github_raw_file(self):
        for name in ("README.md", "install.sh", "install.ps1"):
            urls = re.findall(r"https?://[^\s'\"()<>`]+/install\.(?:sh|ps1)", self.read(name))
            self.assertTrue(urls, name)
            for url in urls:
                self.assertIn(url, (self.RAW + "install.sh", self.RAW + "install.ps1"), name)

    def test_no_dependency_on_the_website(self):
        for name in ("README.md", "install.sh", "install.ps1"):
            self.assertNotIn("antivisions.com", self.read(name), name)

    def test_one_install_line_per_system(self):
        lines = self.read("README.md").splitlines()
        self.assertEqual(lines.count("curl -fsSL %sinstall.sh | sh" % self.RAW), 1)
        self.assertEqual(lines.count("irm %sinstall.ps1 | iex" % self.RAW), 1)


if __name__ == "__main__":
    unittest.main()
