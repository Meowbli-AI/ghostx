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

HOME="$fake_home" "$repo_dir/install.sh" >/dev/null
grep -Fq 'existing-hook' "$fake_home/.codex/hooks.json" || fail "installer removed an existing hook"
hook_count=$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$fake_home/.codex/hooks.json")
assert_eq "$hook_count" "2"
hook_command=$(/usr/bin/plutil -extract hooks.SessionStart.1.hooks.0.command raw -o - "$fake_home/.codex/hooks.json")
assert_eq "$hook_command" "$fake_home/.local/share/ghostx/runtime/libexec/bind-codex-session"
assert_eq "$(stat -f '%Lp' "$fake_home/.codex/hooks.json")" "$original_hooks_mode"
grep -Fq 'theme = Existing Theme' "$fake_home/Library/Application Support/com.mitchellh.ghostty/config" || fail "installer removed Ghostty config"
grep -Fq 'window-save-state = always' "$fake_home/Library/Application Support/com.mitchellh.ghostty/config" || fail "installer did not enable restoration"
grep -Fq '# existing zsh config' "$fake_home/.zshrc" || fail "installer removed zsh config"

# Reinstalling must not duplicate marked blocks or hooks.
HOME="$fake_home" "$repo_dir/install.sh" >/dev/null
assert_eq "$(grep -Fc '# >>> ghostx >>>' "$fake_home/.zshrc")" "1"
assert_eq "$(grep -Fc '# >>> ghostx >>>' "$fake_home/Library/Application Support/com.mitchellh.ghostty/config")" "1"
assert_eq "$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$fake_home/.codex/hooks.json")" "2"

HOME="$fake_home" "$repo_dir/uninstall.sh" >/dev/null
grep -Fq 'existing-hook' "$fake_home/.codex/hooks.json" || fail "uninstaller removed an existing hook"
assert_eq "$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$fake_home/.codex/hooks.json")" "1"
if grep -Fq '# >>> ghostx >>>' "$fake_home/.zshrc"; then
  fail "uninstaller left the zsh block"
fi
cmp -s "$tmp_dir/original-ghostty-config" "$fake_home/Library/Application Support/com.mitchellh.ghostty/config" || fail "uninstaller changed the original Ghostty config"
cmp -s "$tmp_dir/original-zshrc" "$fake_home/.zshrc" || fail "uninstaller changed the original zsh config"

printf '%s\n' "ok"
