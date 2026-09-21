#!/usr/bin/env python3
"""
Merge claude_watch's hook handlers into ~/.claude/settings.json.

Merging, not overwriting: the user may already have hooks (and very likely does).
Every existing event, matcher group and handler is preserved. claude_watch's own
handlers are identified by a marker in the command string so re-running the
installer updates in place instead of duplicating, and uninstall can remove
exactly its own entries and nothing else.

Verified against https://code.claude.com/docs/en/hooks:
  * `async` lives inside the individual handler object, next to type/command.
  * SessionEnd does NOT support async and shares a 1.5s budget across all
    SessionEnd hooks, so it is registered synchronously with a tiny timeout.
  * UserPromptSubmit and Stop take no matcher, so their groups omit the key.
"""

import json
import os
import shutil
import sys
import time

MARKER = "claude-watch-status.sh"

HOME = os.path.expanduser("~")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
SUPPORT_DIR = os.path.join(HOME, "Library", "Application Support", "claude_watch")
SCRIPT_DEST = os.path.join(SUPPORT_DIR, "claude-watch-status.sh")

# Matcher sets taken from the official reference, not from memory.
STOP_FAILURE_MATCHER = "|".join([
    "rate_limit", "overloaded", "authentication_failed", "oauth_org_not_allowed",
    "account_on_hold", "billing_error", "invalid_request", "model_not_found",
    "server_error", "max_output_tokens", "cloud_credential_error", "unknown",
])

# Only the notification types that mean the user is blocking progress.
# The full documented set includes auth_success, elicitation_* and
# quota_auto_resume_*, which would produce false "needs_you" states.
NOTIFICATION_MATCHER = "permission_prompt|idle_prompt|agent_needs_input|agent_completed"

SESSION_START_MATCHER = "startup|resume|clear|compact|fork"
SESSION_END_MATCHER = "clear|resume|logout|prompt_input_exit|other"


def handler(event, *, async_hook=True, timeout=None):
    h = {
        "type": "command",
        "command": f'bash "{SCRIPT_DEST}" {event}',
    }
    if async_hook:
        # Output and exit codes of async hooks are discarded; the status writer
        # must never sit in Claude Code's critical path.
        h["async"] = True
    if timeout is not None:
        h["timeout"] = timeout
    return h


def desired_groups():
    """event name -> the matcher group claude_watch wants registered."""
    return {
        "SessionStart":     {"matcher": SESSION_START_MATCHER, "hooks": [handler("SessionStart")]},
        # No matcher support on these two per the docs.
        "UserPromptSubmit": {"hooks": [handler("UserPromptSubmit")]},
        "Stop":             {"hooks": [handler("Stop")]},
        # SubagentStop as well as Stop. In a subagent context a skill's Stop
        # hook is converted to SubagentStop, so registering only Stop leaves
        # subagent turn-completion invisible. Its matcher is the agent type;
        # ".*" catches every one, including plugin-scoped names.
        "SubagentStop":     {"matcher": ".*", "hooks": [handler("SubagentStop")]},
        "StopFailure":      {"matcher": STOP_FAILURE_MATCHER, "hooks": [handler("StopFailure")]},
        # Needs-you the moment it happens, not six seconds later. AskUserQuestion
        # is a tool call, so its wait is bracketed by Pre/PostToolUse; a
        # permission dialog is announced by PermissionRequest. That last one
        # carries a decision in its output, so it runs synchronously (we print
        # nothing, so the dialog shows as normal) with a short timeout.
        "PreToolUse":        {"matcher": "AskUserQuestion", "hooks": [handler("PreToolUse")]},
        "PostToolUse":       {"matcher": "AskUserQuestion", "hooks": [handler("PostToolUse")]},
        "PermissionRequest": {"hooks": [handler("PermissionRequest", async_hook=False, timeout=5)]},
        "Notification":     {"matcher": NOTIFICATION_MATCHER, "hooks": [handler("Notification")]},
        # SessionEnd: synchronous (async unsupported), shared 1.5s budget,
        # so keep the timeout tight. The script's SessionEnd path is one unlink.
        "SessionEnd":       {"matcher": SESSION_END_MATCHER,
                             "hooks": [handler("SessionEnd", async_hook=False, timeout=2)]},
    }


def is_ours(h):
    return isinstance(h, dict) and MARKER in str(h.get("command", ""))


def load_settings():
    if not os.path.exists(SETTINGS):
        return {}, False
    try:
        with open(SETTINGS) as f:
            text = f.read()
        if not text.strip():
            return {}, False
        return json.loads(text), True
    except (json.JSONDecodeError, OSError) as e:
        print(f"error: could not parse {SETTINGS}: {e}", file=sys.stderr)
        print("Refusing to touch it. Fix or move the file and re-run.", file=sys.stderr)
        sys.exit(1)


def install():
    os.makedirs(os.path.join(SUPPORT_DIR, "sessions"), exist_ok=True)

    # Two layouts to support: the repo (Scripts/ and Resources/ are siblings)
    # and the app bundle (both files land flat in Contents/Resources/).
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "claude-watch-status.sh"),                       # bundle
        os.path.join(os.path.dirname(here), "Resources", "claude-watch-status.sh"),  # repo
    ]
    src = next((c for c in candidates if os.path.exists(c)), None)
    if src is None:
        print("error: status script not found; looked in:", file=sys.stderr)
        for c in candidates:
            print(f"  {c}", file=sys.stderr)
        sys.exit(1)
    shutil.copyfile(src, SCRIPT_DEST)
    os.chmod(SCRIPT_DEST, 0o755)
    print(f"installed status writer -> {SCRIPT_DEST}")

    settings, existed = load_settings()
    if existed:
        backup = f"{SETTINGS}.claude_watch-backup-{int(time.time())}"
        shutil.copyfile(SETTINGS, backup)
        print(f"backed up existing settings -> {backup}")

    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        print("error: 'hooks' in settings.json is not an object; refusing to modify.", file=sys.stderr)
        sys.exit(1)

    added = updated = 0
    for event, group in desired_groups().items():
        existing = hooks.setdefault(event, [])
        if not isinstance(existing, list):
            print(f"warning: hooks.{event} is not a list; skipping.", file=sys.stderr)
            continue

        # Drop only our own handlers, keeping every foreign one untouched.
        touched = False
        for grp in existing:
            if not isinstance(grp, dict):
                continue
            hs = grp.get("hooks")
            if isinstance(hs, list):
                kept = [h for h in hs if not is_ours(h)]
                if len(kept) != len(hs):
                    touched = True
                    grp["hooks"] = kept
        # Remove groups we emptied out (they were ours alone).
        existing[:] = [g for g in existing
                       if not (isinstance(g, dict) and g.get("hooks") == [] and touched)]

        existing.append(group)
        updated += 1 if touched else 0
        added += 0 if touched else 1

    tmp = SETTINGS + ".claude_watch.tmp"
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, SETTINGS)

    print(f"merged hooks into {SETTINGS} ({added} added, {updated} updated)")
    print("Preserved all pre-existing hooks.")


def uninstall():
    settings, existed = load_settings()
    if not existed:
        print("nothing to do: no settings.json")
        return
    backup = f"{SETTINGS}.claude_watch-backup-{int(time.time())}"
    shutil.copyfile(SETTINGS, backup)

    hooks = settings.get("hooks")
    removed = 0
    if isinstance(hooks, dict):
        for event, groups in list(hooks.items()):
            if not isinstance(groups, list):
                continue
            for grp in groups:
                if isinstance(grp, dict) and isinstance(grp.get("hooks"), list):
                    before = len(grp["hooks"])
                    grp["hooks"] = [h for h in grp["hooks"] if not is_ours(h)]
                    removed += before - len(grp["hooks"])
            groups[:] = [g for g in groups
                         if not (isinstance(g, dict) and g.get("hooks") == [])]
            if not groups:
                del hooks[event]
        if not hooks:
            settings.pop("hooks", None)

    tmp = SETTINGS + ".claude_watch.tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, SETTINGS)
    print(f"removed {removed} claude_watch handler(s); backup at {backup}")


def print_config():
    """Print exactly what install() will merge, as the JSON fragment a user
    could paste under "hooks" by hand. Used by the app to show the change
    before it is made, and as the manual fallback when the write fails."""
    print(json.dumps({"hooks": {k: [v] for k, v in desired_groups().items()}}, indent=2))


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "uninstall":
        uninstall()
    elif arg in ("print", "--print"):
        print_config()
    else:
        install()
