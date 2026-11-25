#!/bin/sh
# Ask Bell for Claude Code - macOS installer.
#
#   Install:       curl -fsSL https://raw.githubusercontent.com/metincanaktas/ask-bell/main/install.sh | sh
#   Uninstall:     curl -fsSL https://raw.githubusercontent.com/metincanaktas/ask-bell/main/install.sh | sh -s -- --uninstall
#   From a clone:  ./install.sh [--uninstall] [path/to/settings.json]
#
# Writes the hook script to <config>/ask-bell/bell.sh and adds two hooks to
# <config>/settings.json, where <config> is $CLAUDE_CONFIG_DIR or ~/.claude.
# The settings file is backed up first, only this tool's entries are added
# or removed, the result is validated and the backup is restored on any
# failure. Running it twice changes nothing. Needs only macOS built-ins.

set -u

MARK='# ask-bell'

say() { printf '%s\n' "$*"; }
die() {
	printf 'ask-bell: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Ask Bell for Claude Code - macOS installer

  ./install.sh [--uninstall] [path/to/settings.json]

Without a path it edits $CLAUDE_CONFIG_DIR/settings.json, or
~/.claude/settings.json. Only this tool's two hook entries are added or
removed; a backup of the previous file is kept next to it.
EOF
}

# Follow symlinks to the real file, so a linked settings.json stays a link.
real_path() {
	_p=$1
	_n=0
	while [ -L "$_p" ] && [ "$_n" -lt 40 ]; do
		_l=$(readlink "$_p") || break
		case $_l in
		/*) _p=$_l ;;
		*) _p=$(dirname -- "$_p")/$_l ;;
		esac
		_n=$((_n + 1))
	done
	printf '%s\n' "$_p"
}

# Single-quote a string for sh -c.
quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# The hook itself. Claude Code runs it with the hook JSON on stdin.
write_bell() {
	cat >"$1" <<'BELL'
#!/bin/sh
# Ask Bell - Claude Code hook for macOS (written by install.sh).
#
# Plays a sound and shows a notification when Claude Code asks you a
# question (PreToolUse, matcher AskUserQuestion) or waits for your
# permission (Notification, matcher permission_prompt). It never blocks:
# sound and notification start in the background, it prints nothing and
# always exits 0.
#
#   ASK_BELL_SOUND=/path/file.aiff   sound to play (default: Glass)
#   ASK_BELL_DRY_RUN=1 or --dry-run  print the notification text instead

if [ -p /dev/stdin ] || [ -f /dev/stdin ] || [ -S /dev/stdin ]; then
	# Claude Code sends the JSON through a pipe, a file or a socketpair (what Node gives a child)
	input=$(head -c 200001 2>/dev/null)
else
	input='{}' # started by hand from a terminal, or stdin closed
fi
# The JSON travels as an argument; stay far below the ARG_MAX limit.
[ "${#input}" -le 200000 ] || input='{}'

dry=${ASK_BELL_DRY_RUN:-0}
[ "${1:-}" = "--dry-run" ] && dry=1

# JavaScript for Automation, built into macOS. argv: ["x" + hook JSON, "dry"?]
# The "x" keeps input that starts with "-" from being read as an option.
JXA='
function run(argv) {
	var d = {};
	try { d = JSON.parse(String(argv[0]).slice(1)); } catch (e) { d = {}; }
	if (!d || typeof d !== "object") d = {};
	function text(x) { return typeof x === "string" ? x.replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, " ").replace(/\s+/g, " ").trim() : ""; }
	var cwd = typeof d.cwd === "string" ? d.cwd.replace(/\/+$/, "") : "";
	var project = text(cwd.split("/").pop()) || "Claude";
	var tool = text(d.tool_name), kind = text(d.notification_type);
	var action = "is waiting for you", detail = text(d.message);
	if (tool === "AskUserQuestion") {
		action = "is asking a question";
		var qs = d.tool_input && d.tool_input.questions;
		var q = Array.isArray(qs) && qs[0] && typeof qs[0] === "object" ? qs[0] : {};
		var h = text(q.header), m = text(q.question);
		detail = h && m ? h + ": " + m : (h || m);
	} else if (kind === "permission_prompt" || d.hook_event_name === "PermissionRequest") {
		action = "is waiting for your permission";
		detail = detail || tool;
	} else if (kind.indexOf("elicitation") === 0) {
		action = "is asking a question";
	}
	var body = project + " " + action + (detail ? ": " + detail : "");
	var chars = Array.from(body);
	if (chars.length > 180) body = chars.slice(0, 179).join("") + "…";
	if (argv[1] === "dry") return "Claude Code | " + body;
	var app = Application.currentApplication();
	app.includeStandardAdditions = true;
	app.displayNotification(body, { withTitle: "Claude Code" });
}'

if [ "$dry" = 1 ]; then
	osascript -l JavaScript -e "$JXA" "x$input" dry 2>/dev/null
	exit 0
fi

sound=${ASK_BELL_SOUND:-/System/Library/Sounds/Glass.aiff}
[ -r "$sound" ] || sound=/System/Library/Sounds/Glass.aiff
afplay "$sound" </dev/null >/dev/null 2>&1 &
osascript -l JavaScript -e "$JXA" "x$input" </dev/null >/dev/null 2>&1 &
exit 0
BELL
}

# settings.json merge, JavaScript for Automation (no jq, no Python).
#   add    <settings> <command> <out>   add our two entries
#   remove <settings> <out>             remove only our entries
#   check  <add|remove> <before> <after> [command]
# add/remove never touch <settings>; they write <out> and print "changed"
# or "same". check fails unless <after> is valid JSON, everything outside
# our entries equals <before>, and our entries are present (add) or gone.
write_merge() {
	cat >"$1" <<'MERGE'
ObjC.import("Foundation");
ObjC.import("stdlib");

var MARK = "# ask-bell";
var HOOKS = [
	{ event: "PreToolUse", matcher: "AskUserQuestion" },
	{ event: "Notification", matcher: "permission_prompt" }
];

function fail(msg) { return new Error(msg); }
function isObj(x) { return x !== null && typeof x === "object" && !Array.isArray(x); }

function readText(path) {
	if (!path || !$.NSFileManager.defaultManager.fileExistsAtPath(path)) return null;
	var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
	if (s.isNil()) throw fail("cannot read as UTF-8: " + path);
	return s.js;
}

function noBom(text) { return text && text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text; }

// NSString drops a UTF-8 byte order mark on read; Latin-1 shows the raw bytes.
function hasBom(path) {
	if (!path || !$.NSFileManager.defaultManager.fileExistsAtPath(path)) return false;
	var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSISOLatin1StringEncoding, null);
	return !s.isNil() && /^\u00EF\u00BB\u00BF/.test(s.js);
}

function parse(text, path) {
	text = noBom(text);
	if (text === null || /^\s*$/.test(text)) return {};
	var root;
	try { root = JSON.parse(text); } catch (e) { throw fail("invalid JSON (" + e.message + "): " + path); }
	if (!isObj(root)) throw fail("root is not a JSON object: " + path);
	return root;
}

// Keep the file's own indentation, line endings, final newline and BOM.
function indentOf(text) {
	var m = text && text.match(/\n([ \t]+)\S/);
	return m ? m[1] : "  ";
}

function write(path, root, text, bom) {
	var body = noBom(text);
	var out = JSON.stringify(root, null, indentOf(body));
	if (body === null || /^\s*$/.test(body) || /\n\s*$/.test(body)) out += "\n";
	if (body && body.indexOf("\r\n") !== -1) out = out.replace(/\n/g, "\r\n");
	if (bom) out = "\uFEFF" + out;
	if (!$(out).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
		throw fail("cannot write: " + path);
	}
}

// Ours: "/bin/sh '<...>/ask-bell/bell.sh' # ask-bell", from any folder.
function ours(h) { return isObj(h) && typeof h.command === "string" && /\/ask-bell\/bell\.sh' # ask-bell$/.test(h.command); }
function handler(cmd) { return { type: "command", command: cmd, timeout: 10, async: true }; }

// Removes our handlers, returns how many. A matcher group or an event list
// is deleted only when it became empty because of that.
function strip(root) {
	var hooks = root.hooks, n = 0;
	if (!isObj(hooks)) return 0;
	Object.keys(hooks).forEach(function (ev) {
		var list = hooks[ev], before = n;
		if (!Array.isArray(list)) return;
		for (var i = list.length - 1; i >= 0; i--) {
			var g = list[i];
			if (!isObj(g) || !Array.isArray(g.hooks)) continue;
			var rest = g.hooks.filter(function (h) { return !ours(h); });
			if (rest.length === g.hooks.length) continue;
			n += g.hooks.length - rest.length;
			if (rest.length) g.hooks = rest; else list.splice(i, 1);
		}
		if (n > before && list.length === 0) delete hooks[ev];
	});
	if (n && Object.keys(hooks).length === 0) delete root.hooks;
	return n;
}

function countOurs(root) { return strip(JSON.parse(JSON.stringify(root))); }

// True when exactly our two entries exist, once each, in the expected shape.
function installed(root, cmd) {
	var hooks = root.hooks;
	if (!isObj(hooks)) return false;
	var want = JSON.stringify(handler(cmd)), total = 0;
	var found = HOOKS.map(function () { return 0; });
	Object.keys(hooks).forEach(function (ev) {
		if (!Array.isArray(hooks[ev])) return;
		hooks[ev].forEach(function (g) {
			if (!isObj(g) || !Array.isArray(g.hooks)) return;
			g.hooks.forEach(function (h) {
				if (!ours(h)) return;
				total++;
				HOOKS.forEach(function (k, i) {
					if (k.event === ev && k.matcher === g.matcher && g.hooks.length === 1 &&
						JSON.stringify(h) === want) found[i]++;
				});
			});
		});
	});
	return total === HOOKS.length && found.every(function (c) { return c === 1; });
}

function add(root, cmd) {
	if (!cmd || cmd.indexOf(MARK) === -1) throw fail("missing hook command");
	if (installed(root, cmd)) return false;
	if (root.hooks !== undefined && !isObj(root.hooks)) throw fail("\"hooks\" is not an object; file left untouched");
	HOOKS.forEach(function (k) {
		var list = root.hooks && root.hooks[k.event];
		if (list !== undefined && !Array.isArray(list)) {
			throw fail("\"hooks." + k.event + "\" is not an array; file left untouched");
		}
	});
	strip(root); // drop stale entries, e.g. from an older path
	if (root.hooks === undefined) root.hooks = {};
	HOOKS.forEach(function (k) {
		if (root.hooks[k.event] === undefined) root.hooks[k.event] = [];
		root.hooks[k.event].push({ matcher: k.matcher, hooks: [handler(cmd)] });
	});
	return true;
}

// Everything except our entries, ignoring empty hook containers.
function rest(root) {
	var r = JSON.parse(JSON.stringify(root));
	strip(r);
	if (isObj(r.hooks)) {
		Object.keys(r.hooks).forEach(function (ev) {
			if (Array.isArray(r.hooks[ev]) && r.hooks[ev].length === 0) delete r.hooks[ev];
		});
		if (Object.keys(r.hooks).length === 0) delete r.hooks;
	}
	return JSON.stringify(r);
}

function check(mode, beforePath, afterPath, cmd) {
	var a = parse(readText(beforePath), beforePath);
	var text = readText(afterPath);
	if (text === null) throw fail("file missing: " + afterPath);
	var b;
	try { b = JSON.parse(noBom(text)); } catch (e) { throw fail("result is invalid JSON: " + e.message); }
	if (!isObj(b)) throw fail("result root is not an object");
	if (rest(a) !== rest(b)) throw fail("content outside our hooks changed");
	if (mode === "add" && !installed(b, cmd)) throw fail("hooks missing after install");
	if (mode === "remove" && countOurs(b) !== 0) throw fail("hooks still present after uninstall");
}

function run(argv) {
	try {
		var op = argv[0];
		if (op === "add" || op === "remove") {
			var text = readText(argv[1]), root = parse(text, argv[1]);
			var changed = op === "add" ? add(root, argv[2]) : strip(root) > 0;
			if (changed) write(op === "add" ? argv[3] : argv[2], root, text, hasBom(argv[1]));
			return changed ? "changed" : "same";
		}
		if (op === "check") {
			check(argv[1], argv[2], argv[3], argv[4]);
			return "ok";
		}
		throw fail("unknown command: " + op);
	} catch (e) {
		console.log("ask-bell: " + e.message); // console.log writes to stderr in JXA
		$.exit(2);
	}
}
MERGE
}

main() {
	umask 077 # temporary copies of a private settings file are never readable by others
	mode=install
	target=
	for arg in "$@"; do
		case $arg in
		--uninstall) mode=uninstall ;;
		-h | --help)
			usage
			return 0
			;;
		-*) die "unknown option: $arg (try --help)" ;;
		*)
			[ -z "$target" ] || die "give at most one settings path"
			case $arg in '' | */) die "the settings path must name a file: '$arg'" ;; esac
			target=$arg
			;;
		esac
	done

	[ "$(uname -s 2>/dev/null)" = Darwin ] || die "this installer is for macOS. On Windows run install.ps1 (see README)."
	command -v osascript >/dev/null 2>&1 || die "osascript not found"

	settings=${target:-"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"}
	case $settings in
	*/*) ;;
	*) settings=./$settings ;;
	esac
	config=$(dirname -- "$settings")

	if [ "$mode" = install ]; then
		mkdir -p -- "$config" || die "cannot create folder: $config"
	fi
	if [ -d "$config" ]; then
		config=$(CDPATH='' cd -- "$config" && pwd) || die "cannot open folder: $config"
		settings=$config/$(basename -- "$settings")
	fi
	bell_dir=$config/ask-bell
	bell=$bell_dir/bell.sh
	cmd="/bin/sh $(quote "$bell") $MARK"
	real=$(real_path "$settings")

	if [ -e "$real" ] && [ ! -f "$real" ]; then
		die "not a regular file: $real"
	fi
	if [ "$mode" = uninstall ] && [ ! -e "$real" ]; then
		rm -f -- "$bell"
		rmdir -- "$bell_dir" 2>/dev/null
		say "Not installed (no settings file): $settings"
		return 0
	fi

	# temporary files left by a run that was killed
	# (find, not a bare glob: zsh aborts on a pattern that matches nothing)
	find "$(dirname -- "$real")" -maxdepth 1 -type f -name "$(basename -- "$real").ask-bell-tmp-*" 2>/dev/null |
		while IFS= read -r old; do
			pid=${old##*-}
			case $pid in '' | *[!0-9]*) continue ;; esac
			kill -0 "$pid" 2>/dev/null || rm -f -- "$old"
		done

	work=$(mktemp -d "${TMPDIR:-/tmp}/ask-bell.XXXXXX") || die "cannot create a temporary folder"
	tmp=$real.ask-bell-tmp-$$
	backup=
	moved=0
	# an interrupted run leaves neither a temporary file nor a backup of an untouched file;
	# a signal can land right after the swap, so the backup goes only if the file still equals it
	trap 'rm -rf -- "$work"; rm -f -- "$tmp"; [ "$moved" = 1 ] || ! cmp -s -- "$backup" "$real" || drop_backup' EXIT
	trap 'exit 1' HUP INT TERM
	merge=$work/merge.js
	write_merge "$merge" || die "cannot write to $work"

	if [ -f "$real" ]; then
		backup=$real.ask-bell-backup-$(date +%Y%m%d-%H%M%S)-$$
		cp -p -- "$real" "$backup" || die "cannot back up: $real"
	fi

	if [ "$mode" = install ]; then
		result=$(osascript -l JavaScript "$merge" add "$real" "$cmd" "$tmp")
	else
		result=$(osascript -l JavaScript "$merge" remove "$real" "$tmp")
	fi || {
		drop_backup
		die "settings left untouched: $real"
	}

	if [ "$mode" = install ]; then
		mkdir -p -- "$bell_dir" || die "cannot create folder: $bell_dir"
		write_bell "$bell_dir/.bell.sh.$$" && chmod 755 "$bell_dir/.bell.sh.$$" &&
			mv -f -- "$bell_dir/.bell.sh.$$" "$bell" || {
			rm -f -- "$bell_dir/.bell.sh.$$"
			drop_backup
			die "cannot write: $bell"
		}
	fi

	if [ "$result" = same ]; then
		drop_backup
		if [ "$mode" = install ]; then
			say "Already installed, nothing changed: $settings"
		else
			rm -f -- "$bell"
			rmdir -- "$bell_dir" 2>/dev/null
			say "Not installed, nothing changed: $settings"
		fi
		return 0
	fi

	mode_js=add
	[ "$mode" = install ] || mode_js=remove
	osascript -l JavaScript "$merge" check "$mode_js" "$backup" "$tmp" "$cmd" >/dev/null || {
		drop_backup
		die "validation failed, settings left untouched: $real"
	}

	# Someone (Claude Code itself, a second run) wrote the file meanwhile: do not clobber it.
	if [ -n "$backup" ]; then
		cmp -s -- "$backup" "$real" || {
			drop_backup
			die "settings changed while installing, run the command again: $real"
		}
		chmod "$(/usr/bin/stat -f %Lp "$backup")" "$tmp" 2>/dev/null
	elif [ -e "$real" ]; then
		die "settings file appeared while installing, run the command again: $real"
	fi
	cp -p -- "$tmp" "$work/written" || die "cannot write to $work"
	mv -f -- "$tmp" "$real" || {
		drop_backup
		die "cannot write: $real"
	}
	moved=1

	if ! osascript -l JavaScript "$merge" check "$mode_js" "$backup" "$real" "$cmd" >/dev/null; then
		# restore only what we wrote; a newer save by Claude Code or an editor is left alone
		cmp -s -- "$real" "$work/written" ||
			die "another program changed the settings right after this run; nothing was undone, run the command again: $real"
		if [ -n "$backup" ]; then
			cp -p -- "$backup" "$real" || die "final check failed and the backup could not be restored, copy it back by hand: $backup"
		else
			rm -f -- "$real"
		fi
		die "final check failed, previous settings restored: $real"
	fi

	if [ "$mode" = install ]; then
		say "Installed: $settings"
		say "Hook script: $bell"
	else
		rm -f -- "$bell"
		rmdir -- "$bell_dir" 2>/dev/null
		say "Uninstalled: $settings"
	fi
	[ -z "$backup" ] || say "Backup of the previous file: $backup"
	if [ "$mode" = install ]; then
		say "Open Claude Code sessions pick this up within seconds; if /hooks does not list it, restart the session."
	fi
	return 0
}

drop_backup() {
	[ -z "${backup:-}" ] || rm -f -- "$backup"
}

# braces: a download cut short is a syntax error, never a run without its arguments
{ main "$@"; }
