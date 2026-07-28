#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghostx-test.XXXXXX")
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected '$1' to equal '$2'"
}

state_dir="$tmp_dir/state"
tty_file="$tmp_dir/tty"
mock_log="$tmp_dir/mock.log"
: >"$tty_file"
: >"$mock_log"

session_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
surface_id="11111111-2222-3333-4444-555555555555"

identified_surface=$(
  TERM_PROGRAM=ghostty \
  GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
  GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
  GHOSTX_TTY="$tty_file" \
    "$repo_dir/libexec/identify-ghostty-surface"
)
assert_eq "$identified_surface" "$surface_id"

unbound_state_dir="$tmp_dir/unbound-state"
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"SessionStart\",\"cwd\":\"/tmp/project\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_STATE_DIR="$unbound_state_dir" \
  "$repo_dir/libexec/bind-codex-session"
[ ! -e "$unbound_state_dir/state.json" ] || fail "binding without a surface identity created state"

# A Codex process that predates shell integration can still bind on its next
# prompt by resolving the current Ghostty surface directly from its TTY.
fallback_state_dir="$tmp_dir/fallback-state"
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/tmp/project\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_STATE_DIR="$fallback_state_dir" \
  GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
  GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
  GHOSTX_TTY="$tty_file" \
  "$repo_dir/libexec/bind-codex-session"
fallback_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$fallback_state_dir/state.json")
assert_eq "$fallback_session" "$session_id"

# Hook subprocesses may not have their own controlling TTY. Walk up to the
# Codex ancestor and pass its TTY explicitly to surface identification.
ancestor_bin_dir="$tmp_dir/ancestor-bin"
ancestor_state_dir="$tmp_dir/ancestor-state"
ancestor_tty_log="$tmp_dir/ancestor-tty.log"
mkdir -p "$ancestor_bin_dir"
printf '%s\n' \
  '#!/bin/sh' \
  'case "$2:$4" in' \
  "  tty=:4242) printf '%s\\n' ttys777 ;;" \
  "  tty=:*) printf '%s\\n' '??' ;;" \
  "  ppid=:*) printf '%s\\n' 4242 ;;" \
  'esac' \
  >"$ancestor_bin_dir/ps"
printf '%s\n' \
  '#!/bin/sh' \
  "printf '%s\\n' \"\$GHOSTX_TTY\" >\"\$GHOSTX_TEST_TTY_LOG\"" \
  "printf '%s\\n' '$surface_id'" \
  >"$ancestor_bin_dir/identify"
chmod 755 "$ancestor_bin_dir/ps" "$ancestor_bin_dir/identify"
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/tmp/project\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_TTY= \
  GHOSTX_STATE_DIR="$ancestor_state_dir" \
  GHOSTX_PS="$ancestor_bin_dir/ps" \
  GHOSTX_IDENTIFY_SURFACE="$ancestor_bin_dir/identify" \
  GHOSTX_TEST_TTY_LOG="$ancestor_tty_log" \
  "$repo_dir/libexec/bind-codex-session"
ancestor_tty=$(/usr/bin/sed -n '1p' "$ancestor_tty_log")
assert_eq "$ancestor_tty" "/dev/ttys777"
ancestor_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$ancestor_state_dir/state.json")
assert_eq "$ancestor_session" "$session_id"

# A stalled transcript-owner lookup must fall back before Codex's outer hook
# deadline instead of blocking the user prompt.
printf '%s\n' \
  '#!/bin/sh' \
  'sleep 3' \
  >"$ancestor_bin_dir/slow-lsof"
chmod 755 "$ancestor_bin_dir/slow-lsof"
bounded_state_dir="$tmp_dir/bounded-state"
printf '%s\n' "{\"session_id\":\"$session_id\",\"transcript_path\":\"/tmp/stalled-rollout.jsonl\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/tmp/project\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_TTY= \
  GHOSTX_STATE_DIR="$bounded_state_dir" \
  GHOSTX_PS="$ancestor_bin_dir/ps" \
  GHOSTX_LSOF="$ancestor_bin_dir/slow-lsof" \
  GHOSTX_LSOF_TIMEOUT=1 \
  GHOSTX_IDENTIFY_SURFACE="$ancestor_bin_dir/identify" \
  GHOSTX_TEST_TTY_LOG="$ancestor_tty_log" \
  "$repo_dir/libexec/bind-codex-session"
bounded_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$bounded_state_dir/state.json")
assert_eq "$bounded_session" "$session_id"

# The transcript is a stronger link than process ancestry because Codex hook
# runners do not have to remain descendants of the TUI process.
transcript_bin_dir="$tmp_dir/transcript-bin"
transcript_state_dir="$tmp_dir/transcript-state"
transcript_tty_log="$tmp_dir/transcript-tty.log"
transcript_path="$tmp_dir/rollout-$session_id.jsonl"
mkdir -p "$transcript_bin_dir"
: >"$transcript_path"
printf '%s\n' \
  '#!/bin/sh' \
  "[ \"\$1\" = -t ] || exit 1" \
  "[ \"\$2\" = -- ] || exit 1" \
  "[ \"\$3\" = '$transcript_path' ] || exit 1" \
  "printf '%s\\n' 32397" \
  >"$transcript_bin_dir/lsof"
printf '%s\n' \
  '#!/bin/sh' \
  'case "$2:$4" in' \
  "  comm=:32397) printf '%s\\n' codex ;;" \
  "  tty=:32397) printf '%s\\n' ttys006 ;;" \
  "  *) exit 1 ;;" \
  'esac' \
  >"$transcript_bin_dir/ps"
printf '%s\n' \
  '#!/bin/sh' \
  "printf '%s\\n' \"\$GHOSTX_TTY\" >\"\$GHOSTX_TEST_TTY_LOG\"" \
  "printf '%s\\n' '$surface_id'" \
  >"$transcript_bin_dir/identify"
chmod 755 "$transcript_bin_dir/lsof" "$transcript_bin_dir/ps" "$transcript_bin_dir/identify"
printf '%s\n' "{\"session_id\":\"$session_id\",\"transcript_path\":\"$transcript_path\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/tmp/project\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_TTY= \
  GHOSTX_STATE_DIR="$transcript_state_dir" \
  GHOSTX_PS="$transcript_bin_dir/ps" \
  GHOSTX_LSOF="$transcript_bin_dir/lsof" \
  GHOSTX_IDENTIFY_SURFACE="$transcript_bin_dir/identify" \
  GHOSTX_TEST_TTY_LOG="$transcript_tty_log" \
  "$repo_dir/libexec/bind-codex-session"
transcript_tty=$(/usr/bin/sed -n '1p' "$transcript_tty_log")
assert_eq "$transcript_tty" "/dev/ttys006"
transcript_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$transcript_state_dir/state.json")
assert_eq "$transcript_session" "$session_id"

# Inherited Ghostx variables must never turn an IDE terminal into a Ghostty
# restoration target.
non_ghostty_state_dir="$tmp_dir/non-ghostty-state"
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/tmp/project\"}" |
  TERM_PROGRAM=vscode \
  GHOSTX_SURFACE_ID="$surface_id" \
  GHOSTX_STATE_DIR="$non_ghostty_state_dir" \
  "$repo_dir/libexec/bind-codex-session"
[ ! -e "$non_ghostty_state_dir/state.json" ] || fail "non-Ghostty session created state"

# Installation can backfill a Codex process that has not loaded the new hook.
# The rollout filename supplies session identity without reading its contents.
backfill_bin_dir="$tmp_dir/backfill-bin"
backfill_state_dir="$tmp_dir/backfill-state"
mkdir -p "$backfill_bin_dir"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" 4242' >"$backfill_bin_dir/pgrep"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" ttys777' >"$backfill_bin_dir/ps"
printf '%s\n' '#!/bin/sh' "printf 'n/tmp/rollout-2026-07-27T00-00-00-$session_id.jsonl\\n'" >"$backfill_bin_dir/lsof"
printf '%s\n' '#!/bin/sh' '[ "$GHOSTX_TTY" = /dev/ttys777 ] || exit 1' "printf '%s\\n' '$surface_id'" >"$backfill_bin_dir/identify"
chmod 755 "$backfill_bin_dir"/*
backfilled=$(
  GHOSTX_STATE_DIR="$backfill_state_dir" \
  GHOSTX_PGREP="$backfill_bin_dir/pgrep" \
  GHOSTX_PS="$backfill_bin_dir/ps" \
  GHOSTX_LSOF="$backfill_bin_dir/lsof" \
  GHOSTX_IDENTIFY_SURFACE="$backfill_bin_dir/identify" \
  GHOSTX_BIND_SESSION="$repo_dir/libexec/bind-codex-session" \
    "$repo_dir/libexec/backfill-codex-sessions"
)
assert_eq "$backfilled" "1"
backfilled_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$backfill_state_dir/state.json")
assert_eq "$backfilled_session" "$session_id"

# Later prompts from that old process reuse its unique saved mapping and do
# not need another AppleScript round trip.
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"/tmp/project\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_STATE_DIR="$fallback_state_dir" \
  GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
  GHOSTX_OSASCRIPT=/usr/bin/false \
  GHOSTX_TTY="$tty_file" \
  "$repo_dir/libexec/bind-codex-session"
fallback_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$fallback_state_dir/state.json")
assert_eq "$fallback_session" "$session_id"

# A Ghostty process launched before the first binding must still be marked as
# handled. Creating state later in that same process must not trigger replay.
empty_state_dir="$tmp_dir/empty-state"
empty_state_log="$tmp_dir/empty-state.log"
: >"$empty_state_log"
GHOSTX_STATE_DIR="$empty_state_dir" \
GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
GHOSTX_MOCK_LOG="$empty_state_log" \
GHOSTX_INSTANCE_ID="empty-state-instance" \
GHOSTX_SKIP_WAIT=1 \
  "$repo_dir/libexec/restore-codex-sessions"
[ -f "$empty_state_dir/run/restored-empty-state-instance" ] || fail "no-state startup was not guarded"

printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"SessionStart\",\"cwd\":\"/tmp/project\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID="$surface_id" \
  GHOSTX_STATE_DIR="$state_dir" \
  "$repo_dir/libexec/bind-codex-session"

bound_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$state_dir/state.json")
assert_eq "$bound_session" "$session_id"

cp "$state_dir/state.json" "$empty_state_dir/state.json"
GHOSTX_STATE_DIR="$empty_state_dir" \
GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
GHOSTX_MOCK_LOG="$empty_state_log" \
GHOSTX_INSTANCE_ID="empty-state-instance" \
GHOSTX_SKIP_WAIT=1 \
  "$repo_dir/libexec/restore-codex-sessions"
assert_eq "$(wc -l <"$empty_state_log" | tr -d ' ')" "0"

GHOSTX_STATE_DIR="$state_dir" \
GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
GHOSTX_MOCK_LOG="$mock_log" \
GHOSTX_INSTANCE_ID="test-instance" \
GHOSTX_SKIP_WAIT=1 \
  "$repo_dir/libexec/restore-codex-sessions"

expected="$surface_id\tcodex resume $session_id"
actual=$(cat "$mock_log")
assert_eq "$actual" "$(printf '%b' "$expected")"

# A second shell in the same Ghostty process must not resume duplicates.
GHOSTX_STATE_DIR="$state_dir" \
GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
GHOSTX_MOCK_LOG="$mock_log" \
GHOSTX_INSTANCE_ID="test-instance" \
GHOSTX_SKIP_WAIT=1 \
  "$repo_dir/libexec/restore-codex-sessions"
assert_eq "$(wc -l <"$mock_log" | tr -d ' ')" "1"

# Exercise the installer against an isolated HOME and ensure existing config
# survives the merge.
fake_home="$tmp_dir/home"
mkdir -p "$fake_home/.codex" "$fake_home/Library/Application Support/com.mitchellh.ghostty"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"existing-hook"}]}]}}' >"$fake_home/.codex/hooks.json"
printf '%s\n' 'theme = Existing Theme' >"$fake_home/Library/Application Support/com.mitchellh.ghostty/config"
printf '%s\n' '# existing zsh config' >"$fake_home/.zshrc"
cp "$fake_home/Library/Application Support/com.mitchellh.ghostty/config" "$tmp_dir/original-ghostty-config"
cp "$fake_home/.zshrc" "$tmp_dir/original-zshrc"
original_hooks_mode=$(stat -f '%Lp' "$fake_home/.codex/hooks.json")

HOME="$fake_home" GHOSTX_SKIP_BACKFILL=1 "$repo_dir/install.sh" >/dev/null
grep -Fq 'existing-hook' "$fake_home/.codex/hooks.json" || fail "installer removed an existing hook"
[ -x "$fake_home/.local/share/ghostx/runtime/libexec/run-with-timeout" ] || fail "installer omitted timeout helper"
hook_count=$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$fake_home/.codex/hooks.json")
assert_eq "$hook_count" "2"
hook_command=$(/usr/bin/plutil -extract hooks.SessionStart.1.hooks.0.command raw -o - "$fake_home/.codex/hooks.json")
assert_eq "$hook_command" "$fake_home/.local/share/ghostx/runtime/libexec/bind-codex-session"
assert_eq "$(/usr/bin/plutil -extract hooks.SessionStart.1.hooks.0.timeout raw -o - "$fake_home/.codex/hooks.json")" "10"
assert_eq "$(/usr/bin/plutil -extract hooks.SessionStart.1.matcher raw -o - "$fake_home/.codex/hooks.json")" "startup|resume|clear"
prompt_hook_count=$(/usr/bin/plutil -extract hooks.UserPromptSubmit raw -o - "$fake_home/.codex/hooks.json")
assert_eq "$prompt_hook_count" "1"
prompt_hook_command=$(/usr/bin/plutil -extract hooks.UserPromptSubmit.0.hooks.0.command raw -o - "$fake_home/.codex/hooks.json")
assert_eq "$prompt_hook_command" "$fake_home/.local/share/ghostx/runtime/libexec/bind-codex-session"
assert_eq "$(/usr/bin/plutil -extract hooks.UserPromptSubmit.0.hooks.0.timeout raw -o - "$fake_home/.codex/hooks.json")" "10"
assert_eq "$(stat -f '%Lp' "$fake_home/.codex/hooks.json")" "$original_hooks_mode"
grep -Fq 'theme = Existing Theme' "$fake_home/Library/Application Support/com.mitchellh.ghostty/config" || fail "installer removed Ghostty config"
grep -Fq 'window-save-state = always' "$fake_home/Library/Application Support/com.mitchellh.ghostty/config" || fail "installer did not enable restoration"
grep -Fq '# existing zsh config' "$fake_home/.zshrc" || fail "installer removed zsh config"

# Reinstalling must not duplicate marked blocks or hooks.
/usr/bin/plutil -replace hooks.SessionStart.1.hooks.0.timeout -integer 3 "$fake_home/.codex/hooks.json"
/usr/bin/plutil -replace hooks.UserPromptSubmit.0.hooks.0.timeout -integer 3 "$fake_home/.codex/hooks.json"
HOME="$fake_home" GHOSTX_SKIP_BACKFILL=1 "$repo_dir/install.sh" >/dev/null
assert_eq "$(grep -Fc '# >>> ghostx >>>' "$fake_home/.zshrc")" "1"
assert_eq "$(grep -Fc '# >>> ghostx >>>' "$fake_home/Library/Application Support/com.mitchellh.ghostty/config")" "1"
assert_eq "$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$fake_home/.codex/hooks.json")" "2"
assert_eq "$(/usr/bin/plutil -extract hooks.SessionStart.1.hooks.0.timeout raw -o - "$fake_home/.codex/hooks.json")" "10"
assert_eq "$(/usr/bin/plutil -extract hooks.UserPromptSubmit raw -o - "$fake_home/.codex/hooks.json")" "1"
assert_eq "$(/usr/bin/plutil -extract hooks.UserPromptSubmit.0.hooks.0.timeout raw -o - "$fake_home/.codex/hooks.json")" "10"

HOME="$fake_home" "$repo_dir/uninstall.sh" >/dev/null
grep -Fq 'existing-hook' "$fake_home/.codex/hooks.json" || fail "uninstaller removed an existing hook"
assert_eq "$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$fake_home/.codex/hooks.json")" "1"
assert_eq "$(/usr/bin/plutil -extract hooks.UserPromptSubmit raw -o - "$fake_home/.codex/hooks.json")" "0"
if grep -Fq '# >>> ghostx >>>' "$fake_home/.zshrc"; then
  fail "uninstaller left the zsh block"
fi
cmp -s "$tmp_dir/original-ghostty-config" "$fake_home/Library/Application Support/com.mitchellh.ghostty/config" || fail "uninstaller changed the original Ghostty config"
cmp -s "$tmp_dir/original-zshrc" "$fake_home/.zshrc" || fail "uninstaller changed the original zsh config"

printf '%s\n' "ok"
