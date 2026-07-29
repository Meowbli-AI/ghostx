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

session_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
surface_id="11111111-2222-3333-4444-555555555555"
project_dir="$tmp_dir/project"
mkdir -p "$project_dir"
project_dir=$(CDPATH= cd -- "$project_dir" && pwd -P)

# A completed command must not wait for the watchdog's full deadline.
timeout_started=$(/bin/date +%s)
"$repo_dir/libexec/run-with-timeout" 8 /usr/bin/true
timeout_elapsed=$(( $(/bin/date +%s) - timeout_started ))
[ "$timeout_elapsed" -lt 7 ] || fail "timeout helper waited after command completion"

# Focused-terminal lookup is read-only and accepts only the caller's cwd.
identified_surface=$(
  TERM_PROGRAM=ghostty \
  GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
  GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
  GHOSTX_MOCK_FOCUSED_CWD="$project_dir" \
  GHOSTX_MOCK_SURFACE_ID="$surface_id" \
    "$repo_dir/libexec/identify-ghostty-surface" "$project_dir"
)
assert_eq "$identified_surface" "$surface_id"

mismatched_surface=$(
  TERM_PROGRAM=ghostty \
  GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
  GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
  GHOSTX_MOCK_FOCUSED_CWD="$tmp_dir/other" \
  GHOSTX_MOCK_SURFACE_ID="$surface_id" \
    "$repo_dir/libexec/identify-ghostty-surface" "$project_dir"
)
assert_eq "$mismatched_surface" ""

if rg -n 'ghostx-surface:|22;0t|23;0t' \
  "$repo_dir/libexec" "$repo_dir/shell" "$repo_dir/applescript" >/dev/null; then
  fail "runtime still contains title mutation"
fi

# A prompt in the focused Ghostty terminal binds progressively without a TTY
# probe or a shell restart.
focused_state_dir="$tmp_dir/focused-state"
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$project_dir\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_STATE_DIR="$focused_state_dir" \
  GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
  GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
  GHOSTX_MOCK_FOCUSED_CWD="$project_dir" \
  GHOSTX_MOCK_SURFACE_ID="$surface_id" \
  "$repo_dir/libexec/bind-codex-session"
focused_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$focused_state_dir/state.json")
assert_eq "$focused_session" "$session_id"

# A cwd mismatch is ambiguous, so it must remain an unbound successful no-op.
mismatch_state_dir="$tmp_dir/mismatch-state"
printf '%s\n' "{\"session_id\":\"ffffffff-1111-2222-3333-444444444444\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$project_dir\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_STATE_DIR="$mismatch_state_dir" \
  GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
  GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
  GHOSTX_MOCK_FOCUSED_CWD="$tmp_dir/other" \
  GHOSTX_MOCK_SURFACE_ID="$surface_id" \
  "$repo_dir/libexec/bind-codex-session"
[ ! -e "$mismatch_state_dir/state.json" ] || fail "cwd mismatch created state"

# Once a session has a unique saved mapping, later prompts reuse it without
# another AppleScript lookup.
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$project_dir\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_STATE_DIR="$focused_state_dir" \
  GHOSTX_OSASCRIPT=/usr/bin/false \
  "$repo_dir/libexec/bind-codex-session"
reused_session=$(/usr/bin/plutil -extract "surfaces.$surface_id.session_id" raw -o - "$focused_state_dir/state.json")
assert_eq "$reused_session" "$session_id"

# Inherited variables must never bind an IDE terminal as a Ghostty surface.
non_ghostty_state_dir="$tmp_dir/non-ghostty-state"
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$project_dir\"}" |
  TERM_PROGRAM=vscode \
  GHOSTX_SURFACE_ID="$surface_id" \
  GHOSTX_STATE_DIR="$non_ghostty_state_dir" \
  "$repo_dir/libexec/bind-codex-session"
[ ! -e "$non_ghostty_state_dir/state.json" ] || fail "non-Ghostty session created state"

# The binder remains strictly below Codex's outer hook deadline.
slow_identify="$tmp_dir/slow-identify"
printf '%s\n' '#!/bin/sh' 'sleep 6' "printf '%s\\n' '$surface_id'" >"$slow_identify"
chmod 755 "$slow_identify"
hard_cap_state_dir="$tmp_dir/hard-cap-state"
hard_cap_started=$(/bin/date +%s)
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$project_dir\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID= \
  GHOSTX_STATE_DIR="$hard_cap_state_dir" \
  GHOSTX_BIND_TIMEOUT=1 \
  GHOSTX_IDENTIFY_SURFACE="$slow_identify" \
  "$repo_dir/libexec/bind-codex-session"
hard_cap_elapsed=$(( $(/bin/date +%s) - hard_cap_started ))
[ "$hard_cap_elapsed" -lt 5 ] || fail "binder exceeded its total timeout"
[ ! -e "$hard_cap_state_dir/state.json" ] || fail "timed-out binder wrote state"

# A Ghostty process launched before the first binding is claimed so creating
# state later cannot replay commands into already-running terminals.
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

state_dir="$tmp_dir/state"
printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"SessionStart\",\"cwd\":\"$project_dir\"}" |
  TERM_PROGRAM=ghostty \
  GHOSTX_SURFACE_ID="$surface_id" \
  GHOSTX_STATE_DIR="$state_dir" \
  "$repo_dir/libexec/bind-codex-session"

cp "$state_dir/state.json" "$empty_state_dir/state.json"
GHOSTX_STATE_DIR="$empty_state_dir" \
GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
GHOSTX_MOCK_LOG="$empty_state_log" \
GHOSTX_INSTANCE_ID="empty-state-instance" \
GHOSTX_SKIP_WAIT=1 \
  "$repo_dir/libexec/restore-codex-sessions"
assert_eq "$(wc -l <"$empty_state_log" | tr -d ' ')" "0"

# Restoration exports the known surface ID before resuming the exact session.
mock_log="$tmp_dir/mock.log"
: >"$mock_log"
GHOSTX_STATE_DIR="$state_dir" \
GHOSTX_APPLESCRIPT_DIR="$repo_dir/applescript" \
GHOSTX_OSASCRIPT="$repo_dir/tests/mock-osascript.sh" \
GHOSTX_MOCK_LOG="$mock_log" \
GHOSTX_INSTANCE_ID="test-instance" \
GHOSTX_SKIP_WAIT=1 \
  "$repo_dir/libexec/restore-codex-sessions"

expected="$surface_id\texport GHOSTX_SURFACE_ID='$surface_id'; codex -c check_for_update_on_startup=false resume '$session_id'"
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

HOME="$fake_home" "$repo_dir/install.sh" >/dev/null
grep -Fq 'existing-hook' "$fake_home/.codex/hooks.json" || fail "installer removed an existing hook"
[ -x "$fake_home/.local/share/ghostx/runtime/libexec/run-with-timeout" ] || fail "installer omitted timeout helper"
[ -f "$fake_home/.local/share/ghostx/runtime/applescript/find-focused-terminal.applescript" ] || fail "installer omitted focused-terminal helper"
[ ! -e "$fake_home/.local/share/ghostx/runtime/applescript/find-terminal-by-title.applescript" ] || fail "installer retained title helper"
[ ! -e "$fake_home/.local/share/ghostx/runtime/libexec/backfill-codex-sessions" ] || fail "installer retained unsafe backfill"
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
HOME="$fake_home" "$repo_dir/install.sh" >/dev/null
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
