#!/bin/bash
# claude-watch-status.sh — status writer for claude_watch.
#
# Invoked by Claude Code hooks with the event name as $1. Reads the hook JSON
# payload on stdin and writes a per-session file into the sessions directory.
#
# THREE RULES THIS FILE MUST NEVER BREAK:
#   1. It exits 0 on every path. Exit code 2 from a Stop hook prevents Claude
#      from stopping; a non-zero exit from UserPromptSubmit erases the user's
#      prompt. The whole body therefore runs inside a wrapper that cannot
#      propagate a failure, and the file ends in a bare `exit 0`.
#   2. It is registered async everywhere it can be, so it never sits in Claude
#      Code's critical path.
#   3. The SessionEnd path is trivial — one unlink — because all SessionEnd
#      hooks share a 1.5s budget and cannot run async.
#
# No `set -e`: a failing command must never abort this script.

__claude_watch_main() {
  local event="$1"

  local support_dir="${HOME}/Library/Application Support/claude_watch"
  local sessions_dir="${support_dir}/sessions"

  local payload=""
  # Never block forever if stdin is a terminal or is never closed.
  if [ ! -t 0 ]; then
    payload="$(cat 2>/dev/null)"
  fi
  [ -z "$payload" ] && payload='{}'

  # jq is the happy path. Without it we degrade to worse names, never to nothing.
  local jq_bin=""
  for candidate in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [ -x "$candidate" ] && { jq_bin="$candidate"; break; }
  done
  [ -z "$jq_bin" ] && jq_bin="$(command -v jq 2>/dev/null)"

  local session_id="" cwd="" transcript_path="" notification_type=""
  local error_type="" end_reason="" last_message=""

  if [ -n "$jq_bin" ]; then
    # One jq pass, one field per line. NOT @tsv: tab is IFS whitespace, so
    # `read` collapses consecutive tabs and empty middle fields shift the
    # remaining values left. Line-delimited output preserves empty fields.
    local parsed
    parsed="$(printf '%s' "$payload" | "$jq_bin" -r '
      (.session_id        // ""),
      (.cwd               // ""),
      (.transcript_path   // ""),
      (.notification_type // ""),
      (.error_type        // ""),
      (.end_reason        // ""),
      ((.last_assistant_message // "") | gsub("[\n\t\r]"; " "))' 2>/dev/null)"
    if [ -n "$parsed" ]; then
      local __cw_vals=()
      while IFS= read -r __cw_line; do __cw_vals+=("$__cw_line"); done <<< "$parsed"
      session_id="${__cw_vals[0]:-}"
      cwd="${__cw_vals[1]:-}"
      transcript_path="${__cw_vals[2]:-}"
      notification_type="${__cw_vals[3]:-}"
      error_type="${__cw_vals[4]:-}"
      end_reason="${__cw_vals[5]:-}"
      last_message="${__cw_vals[6]:-}"
    fi
  fi

  # Fallback extraction if jq is missing or produced nothing.
  if [ -z "$session_id" ]; then
    session_id="$(printf '%s' "$payload" \
      | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi
  if [ -z "$cwd" ]; then
    cwd="$(printf '%s' "$payload" \
      | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi

  # No session id means nothing addressable to write. Leave quietly.
  [ -z "$session_id" ] && return 0

  # Reject anything that could escape the sessions directory.
  case "$session_id" in
    *[!A-Za-z0-9._-]* | "" | "." | ".." ) return 0 ;;
  esac

  local target="${sessions_dir}/${session_id}.json"

  # ---- SessionEnd: trivial path, shared 1.5s budget, runs synchronously. ----
  if [ "$event" = "SessionEnd" ]; then
    rm -f "$target" 2>/dev/null
    return 0
  fi

  mkdir -p "$sessions_dir" 2>/dev/null || return 0

  # ---- Map event + matcher to a state. ----
  local state=""
  case "$event" in
    SessionStart)      state="idle" ;;
    UserPromptSubmit)  state="working" ;;
    Stop|SubagentStop) state="done" ;;
    StopFailure)       state="failed" ;;
    # A question or a permission dialog is waiting on the user right now.
    PreToolUse|PermissionRequest) state="needs_you" ;;
    # The question was answered; the turn continues.
    PostToolUse)       state="working" ;;
    Notification)
      case "$notification_type" in
        agent_completed) state="done" ;;
        *)               state="needs_you" ;;
      esac
      ;;
    *)                 state="idle" ;;
  esac

  # ---- Liveness: walk up to the Claude Code process and record its pid. ----
  # The app calls kill(pid, 0) on this, which beats time-based staleness.
  local owner_pid="$PPID"
  local ancestor_name=""
  local walk_pid="$PPID"
  local hop=0
  while [ "$hop" -lt 8 ] && [ -n "$walk_pid" ] && [ "$walk_pid" -gt 1 ] 2>/dev/null; do
    local pinfo comm parent
    pinfo="$(ps -o ppid=,comm= -p "$walk_pid" 2>/dev/null)"
    [ -z "$pinfo" ] && break
    parent="$(printf '%s' "$pinfo" | awk '{print $1}')"
    comm="$(printf '%s' "$pinfo" | awk '{$1=""; sub(/^ /,""); print}')"
    [ -z "$ancestor_name" ] && ancestor_name="${comm##*/}"
    case "${comm##*/}" in
      *claude*|*node*|*Code\ Helper*|*Electron*)
        owner_pid="$walk_pid"
        ancestor_name="${comm##*/}"
        break
        ;;
    esac
    walk_pid="$parent"
    hop=$((hop + 1))
  done

  # ---- Chat name: the title Claude Code itself gives the chat. ----
  # Claude Code appends `{"type":"ai-title","aiTitle":"..."}` records to the
  # transcript once it has named the session; the newest one is the name shown
  # in its own session picker. grep over the file is milliseconds even at tens
  # of megabytes. Before a title exists, fall back to the first real prompt,
  # read line by line (a byte cut mid-line used to make jq fail and lose the
  # name entirely). Any failure degrades to the cwd folder name, never blank.
  local chat_name=""
  if [ -n "$jq_bin" ] && [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
    chat_name="$(grep -h '"type":"ai-title"' "$transcript_path" 2>/dev/null | tail -n 1 \
      | "$jq_bin" -r '.aiTitle // ""' 2>/dev/null | tr '\n' ' ' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-80)"
    if [ -z "$chat_name" ]; then
      chat_name="$(head -n 400 "$transcript_path" 2>/dev/null | "$jq_bin" -R -r '
        fromjson? | select(.type == "user")
        | (.message.content?)
        | if type == "string" then .
          elif type == "array" then ([ .[] | select(.type? == "text") | .text? ] | join(" "))
          else empty end
        | select(. != null and . != "" and (startswith("<") | not))' 2>/dev/null \
        | head -n 1 | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-80)"
    fi
  fi
  [ -z "$chat_name" ] && chat_name="${cwd##*/}"

  local project_name="${cwd##*/}"

  # ---- Environment signals, recorded raw. The app decides what to display. ----
  local term_program="${TERM_PROGRAM:-}"
  local term_version="${TERM_PROGRAM_VERSION:-}"
  local claude_remote="${CLAUDE_CODE_REMOTE:-}"

  # ---- Focus hints: enough to find the exact tab or window later. ----
  # Each terminal exposes its own handle; the app uses whichever is present.
  # __CFBundleIdentifier names the GUI app that spawned this process (an IDE
  # extension host has no TERM_PROGRAM, but it does have this). The tty ties a
  # Terminal.app tab to a session; VSCODE_PID is the IDE's main process.
  local term_session_id="${TERM_SESSION_ID:-}"
  local iterm_session_id="${ITERM_SESSION_ID:-}"
  local kitty_window_id="${KITTY_WINDOW_ID:-}"
  local wezterm_pane="${WEZTERM_PANE:-}"
  local host_bundle_id="${__CFBundleIdentifier:-}"
  local host_pid="${VSCODE_PID:-}"
  local owner_tty=""
  owner_tty="$(ps -o tty= -p "$owner_pid" 2>/dev/null | tr -d ' ')"
  [ "$owner_tty" = "??" ] && owner_tty=""
  case "$host_pid" in ''|*[!0-9]*) host_pid="" ;; esac

  local now
  now="$(date +%s)"

  # ---- Atomic write: temp file in the same directory, then mv. ----
  # A reader never sees a partial file; mv within a filesystem is atomic.
  local tmp="${target}.tmp.$$"

  # Escape for JSON string literals: backslash, quote, then control chars.
  __cw_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' \
      | tr -d '\000-\010\013\014\016-\037'
  }

  {
    printf '{'
    printf '"schema":1,'
    printf '"session_id":"%s",' "$(__cw_json_escape "$session_id")"
    printf '"state":"%s",' "$(__cw_json_escape "$state")"
    printf '"event":"%s",' "$(__cw_json_escape "$event")"
    printf '"chat_name":"%s",' "$(__cw_json_escape "$chat_name")"
    printf '"project_name":"%s",' "$(__cw_json_escape "$project_name")"
    printf '"cwd":"%s",' "$(__cw_json_escape "$cwd")"
    printf '"transcript_path":"%s",' "$(__cw_json_escape "$transcript_path")"
    printf '"owner_pid":%s,' "${owner_pid:-0}"
    printf '"ancestor_name":"%s",' "$(__cw_json_escape "$ancestor_name")"
    printf '"term_program":"%s",' "$(__cw_json_escape "$term_program")"
    printf '"term_program_version":"%s",' "$(__cw_json_escape "$term_version")"
    printf '"claude_code_remote":"%s",' "$(__cw_json_escape "$claude_remote")"
    printf '"term_session_id":"%s",' "$(__cw_json_escape "$term_session_id")"
    printf '"iterm_session_id":"%s",' "$(__cw_json_escape "$iterm_session_id")"
    printf '"kitty_window_id":"%s",' "$(__cw_json_escape "$kitty_window_id")"
    printf '"wezterm_pane":"%s",' "$(__cw_json_escape "$wezterm_pane")"
    printf '"host_bundle_id":"%s",' "$(__cw_json_escape "$host_bundle_id")"
    printf '"host_pid":%s,' "${host_pid:-0}"
    printf '"owner_tty":"%s",' "$(__cw_json_escape "$owner_tty")"
    printf '"notification_type":"%s",' "$(__cw_json_escape "$notification_type")"
    printf '"error_type":"%s",' "$(__cw_json_escape "$error_type")"
    printf '"end_reason":"%s",' "$(__cw_json_escape "$end_reason")"
    printf '"last_message":"%s",' "$(__cw_json_escape "$last_message")"
    printf '"updated_at":%s' "$now"
    printf '}'
  } > "$tmp" 2>/dev/null

  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi

  return 0
}

# Run the body so no failure inside it can ever escape. Redirect stdout to
# stderr-free oblivion: async hooks discard output, but SessionEnd is not async
# and stray stdout there would be surfaced to the user.
__claude_watch_main "${1:-unknown}" >/dev/null 2>&1

# Unconditional. Nothing above this line may change the exit status.
exit 0
