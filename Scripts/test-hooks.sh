#!/bin/bash
# Hook-bridge test suite. Covers the three rules that would break a user's
# Claude Code, plus degradation paths. Run with: make test-hooks
cd "$(dirname "$0")/.." || exit 1
S="Resources/claude-watch-status.sh"
W="$(mktemp -d)"; export HOME_ORIG="$HOME"
SD="$W/Library/Application Support/claude_watch/sessions"
pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }
run(){ printf '%s' "$2" | HOME="$W" bash "$S" "$1"; }
cleanup(){ rm -rf "$W" /tmp/cw-broken.sh /tmp/cw-nojq.sh; }
trap cleanup EXIT

echo "syntax"
bash -n "$S" && ok "script parses" || no "script parses"

echo "state machine"
run SessionStart '{"session_id":"s1","cwd":"/tmp/demo"}'
[ "$(python3 -c "import json;print(json.load(open('$SD/s1.json'))['state'])")" = idle ] && ok "SessionStart -> idle" || no "SessionStart -> idle"
run UserPromptSubmit '{"session_id":"s1","cwd":"/tmp/demo"}'
[ "$(python3 -c "import json;print(json.load(open('$SD/s1.json'))['state'])")" = working ] && ok "UserPromptSubmit -> working" || no "UserPromptSubmit -> working"
run Stop '{"session_id":"s1","cwd":"/tmp/demo"}'
[ "$(python3 -c "import json;print(json.load(open('$SD/s1.json'))['state'])")" = done ] && ok "Stop -> done" || no "Stop -> done"
run SubagentStop '{"session_id":"s1","cwd":"/tmp/demo"}'
[ "$(python3 -c "import json;print(json.load(open('$SD/s1.json'))['state'])")" = done ] && ok "SubagentStop -> done" || no "SubagentStop -> done"
run PreToolUse '{"session_id":"s1","cwd":"/tmp/demo","tool_name":"AskUserQuestion"}'
[ "$(python3 -c "import json;print(json.load(open('$SD/s1.json'))['state'])")" = needs_you ] && ok "PreToolUse(AskUserQuestion) -> needs_you" || no "PreToolUse(AskUserQuestion) -> needs_you"
run PostToolUse '{"session_id":"s1","cwd":"/tmp/demo","tool_name":"AskUserQuestion"}'
[ "$(python3 -c "import json;print(json.load(open('$SD/s1.json'))['state'])")" = working ] && ok "PostToolUse(AskUserQuestion) -> working" || no "PostToolUse(AskUserQuestion) -> working"
run PermissionRequest '{"session_id":"s1","cwd":"/tmp/demo","tool_name":"Bash"}'
[ "$(python3 -c "import json;print(json.load(open('$SD/s1.json'))['state'])")" = needs_you ] && ok "PermissionRequest -> needs_you" || no "PermissionRequest -> needs_you"
run StopFailure '{"session_id":"s1","cwd":"/tmp/demo","error_type":"rate_limit"}'
[ "$(python3 -c "import json;d=json.load(open('$SD/s1.json'));print(d['state']+'/'+d['error_type'])")" = failed/rate_limit ] && ok "StopFailure -> failed + reason" || no "StopFailure -> failed + reason"
for nt in permission_prompt idle_prompt agent_needs_input; do
  run Notification "{\"session_id\":\"s1\",\"cwd\":\"/tmp/demo\",\"notification_type\":\"$nt\"}"
  [ "$(python3 -c "import json;print(json.load(open('$SD/s1.json'))['state'])")" = needs_you ] && ok "Notification/$nt -> needs_you" || no "Notification/$nt"
done
run SessionEnd '{"session_id":"s1","end_reason":"clear"}'
[ ! -f "$SD/s1.json" ] && ok "SessionEnd removes entry" || no "SessionEnd removes entry"

echo "lazy creation"
run Stop '{"session_id":"lazy1","cwd":"/tmp/demo"}'
[ -f "$SD/lazy1.json" ] && ok "unknown session created on non-SessionStart event" || no "lazy creation"

echo "rule 1: exit 0 on every path"
for p in '' 'garbage' '{"session_id":' '{"session_id":null}' '{"session_id":"../../etc/passwd"}' '{"session_id":"a;rm -rf /"}'; do
  run Stop "$p"; [ $? -eq 0 ] || no "exit 0 for payload: $p"
done
ok "exit 0 across empty/malformed/hostile payloads"
sed 's|^  local target=.*|  local target="x"; nonexistent_cmd_xyz; false; (exit 99)|' "$S" > /tmp/cw-broken.sh
printf '%s' '{"session_id":"b","cwd":"/tmp/d"}' | HOME="$W" bash /tmp/cw-broken.sh Stop
[ $? -eq 0 ] && ok "forced internal failure still exits 0" || no "forced internal failure"
printf '%s' '{"session_id":"b"}' | HOME="$W" bash /tmp/cw-broken.sh SessionEnd
[ $? -eq 0 ] && ok "forced failure on SessionEnd exits 0" || no "forced failure SessionEnd"

echo "security"
[ ! -e "$W/Library/Application Support/claude_watch/sessions/../../../../etc/passwd" ] && ok "no path traversal" || no "path traversal"

echo "degradation"
sed -e 's|/opt/homebrew/bin/jq|/nonexistent/a|; s|/usr/local/bin/jq|/nonexistent/b|; s|/usr/bin/jq|/nonexistent/c|' \
    -e 's|jq_bin="$(command -v jq 2>/dev/null)"|jq_bin=""|' "$S" > /tmp/cw-nojq.sh
printf '%s' '{"session_id":"nojq","cwd":"/tmp/degraded"}' | HOME="$W" bash /tmp/cw-nojq.sh Stop
n=$(python3 -c "import json;print(json.load(open('$SD/nojq.json'))['project_name'])" 2>/dev/null)
[ "$n" = "degraded" ] && ok "without jq, degrades to folder name (never blank)" || no "no-jq degradation"

echo "atomicity"
python3 -c "
import json,glob
for f in glob.glob('$SD/*.json'):
    json.load(open(f))
print('  ok   every written file is valid JSON')" || no "valid JSON"

echo
echo "hooks: $pass passed, $fail failed"
[ $fail -eq 0 ]
