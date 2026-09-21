#!/usr/bin/env python3
"""Installer merge tests: the user's existing hooks must survive untouched."""
import json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALLER = os.path.join(ROOT, "Scripts", "install-hooks.py")

# A settings file shaped like a real one: other top-level keys, pre-existing
# hooks on events we also register (SessionStart) and ones we don't (PreToolUse).
EXISTING = {
    "permissions": {"allow": ["Bash(ls:*)"]},
    "theme": "dark",
    "hooks": {
        "SessionStart": [
            {"hooks": [{"type": "command", "command": "node /u/.claude/hooks/their-update.js"}]},
            {"hooks": [{"type": "command", "command": "bash /u/.claude/hooks/their-state.sh"}]},
        ],
        "PreToolUse": [
            {"matcher": "Write|Edit",
             "hooks": [{"type": "command", "command": "node /u/.claude/hooks/guard.js", "timeout": 5}]},
        ],
        "Stop": [
            {"hooks": [{"type": "command", "command": "bash /u/.claude/hooks/their-stop.sh"}]},
        ],
    },
}

def handlers(d):
    out = []
    for ev, groups in d.get("hooks", {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                out.append((ev, h.get("command")))
    return out

def run(home, *args):
    env = dict(os.environ, HOME=home)
    return subprocess.run([sys.executable, INSTALLER, *args],
                          capture_output=True, text=True, env=env)

def main():
    failures = []
    def check(cond, label):
        print(("  ok   " if cond else "  FAIL ") + label)
        if not cond:
            failures.append(label)

    with tempfile.TemporaryDirectory() as home:
        os.makedirs(os.path.join(home, ".claude"))
        settings_path = os.path.join(home, ".claude", "settings.json")
        with open(settings_path, "w") as f:
            json.dump(EXISTING, f, indent=2)

        print("merge into existing settings")
        r = run(home)
        check(r.returncode == 0, "installer exits 0")
        new = json.load(open(settings_path))

        for k, v in EXISTING.items():
            if k != "hooks":
                check(new.get(k) == v, f"top-level key '{k}' preserved")

        before = set(handlers(EXISTING))
        after = set(handlers(new))
        check(before <= after, "every pre-existing handler preserved")
        check(len(after - before) == 10, "exactly 10 claude_watch handlers added")

        ours = {ev: h for ev, h in
                [(ev, h) for ev, groups in new["hooks"].items() for g in groups
                 for h in g.get("hooks", []) if "claude-watch-status.sh" in h.get("command", "")]}
        check(set(ours) == {"SessionStart", "UserPromptSubmit", "Stop", "SubagentStop",
                            "StopFailure", "Notification", "SessionEnd",
                            "PreToolUse", "PostToolUse", "PermissionRequest"},
              "all ten events registered")
        check("async" not in ours["PermissionRequest"],
              "PermissionRequest is NOT async (its output is a decision)")

        print("documented hook rules")
        check("async" not in ours["SessionEnd"],
              "SessionEnd is NOT async (docs: unsupported, 1.5s shared budget)")
        check(ours["SessionEnd"].get("timeout") == 2, "SessionEnd timeout kept tight")
        check(all(ours[e].get("async") is True for e in
                  ["SessionStart", "UserPromptSubmit", "Stop", "SubagentStop",
                   "StopFailure", "Notification", "PreToolUse", "PostToolUse"]),
              "every other handler is async:true")
        for ev in ("UserPromptSubmit", "Stop"):
            grp = [g for g in new["hooks"][ev]
                   if any("claude-watch" in h.get("command", "") for h in g.get("hooks", []))][0]
            check("matcher" not in grp, f"{ev} group omits matcher (no matcher support)")

        print("idempotency")
        for _ in range(3):
            run(home)
        again = json.load(open(settings_path))
        n_ours = sum(1 for ev, c in handlers(again) if "claude-watch-status.sh" in (c or ""))
        n_theirs = sum(1 for ev, c in handlers(again) if "claude-watch-status.sh" not in (c or ""))
        check(n_ours == 10, "re-running does not duplicate handlers")
        check(n_theirs == len(before), "re-running leaves foreign handlers alone")

        print("uninstall")
        run(home, "uninstall")
        final = json.load(open(settings_path))
        n_ours = sum(1 for ev, c in handlers(final) if "claude-watch-status.sh" in (c or ""))
        check(n_ours == 0, "uninstall removes every claude_watch handler")
        check(set(handlers(EXISTING)) <= set(handlers(final)),
              "uninstall leaves every foreign handler intact")

    with tempfile.TemporaryDirectory() as home:
        print("fresh install (no settings.json)")
        os.makedirs(os.path.join(home, ".claude"))
        r = run(home)
        check(r.returncode == 0, "installs cleanly with no pre-existing settings")
        d = json.load(open(os.path.join(home, ".claude", "settings.json")))
        check(len(handlers(d)) == 10, "registers ten handlers on a fresh machine")

    with tempfile.TemporaryDirectory() as home:
        print("corrupt settings.json")
        os.makedirs(os.path.join(home, ".claude"))
        with open(os.path.join(home, ".claude", "settings.json"), "w") as f:
            f.write("{ this is not valid json")
        r = run(home)
        check(r.returncode != 0, "refuses to touch unparseable settings")
        check(open(os.path.join(home, ".claude", "settings.json")).read() == "{ this is not valid json",
              "leaves unparseable settings byte-identical")

    print()
    print(f"installer: {'ALL PASS' if not failures else str(len(failures)) + ' FAILED'}")
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
