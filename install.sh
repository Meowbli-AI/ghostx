#!/bin/sh

set -eu
umask 077

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
runtime_dir="$data_home/ghostx/runtime"
codex_dir=${CODEX_HOME:-"$HOME/.codex"}
hooks_file="$codex_dir/hooks.json"
state_dir=${GHOSTX_STATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/ghostx"}
zshrc=${ZDOTDIR:-$HOME}/.zshrc
ghostty_config=${GHOSTX_GHOSTTY_CONFIG:-"$HOME/Library/Application Support/com.mitchellh.ghostty/config"}

ghostty_instance_id() {
  identity=""
  ghostty_pids=$(
    ps -axo pid=,command= 2>/dev/null |
      awk '$2 ~ /\/Ghostty\.app\/Contents\/MacOS\/ghostty$/ { print $1 }' |
      sort -n
  )
  for ghostty_pid in $ghostty_pids; do
    started_at=$(ps -o lstart= -p "$ghostty_pid" 2>/dev/null || true)
    identity="${identity}${ghostty_pid}-${started_at}-"
  done
  printf '%s' "$identity" | tr -cd 'A-Za-z0-9_-'
}

mkdir -p "$runtime_dir/libexec" "$runtime_dir/applescript" "$runtime_dir/shell"
cp "$repo_dir/libexec/bind-codex-session" "$runtime_dir/libexec/"
cp "$repo_dir/libexec/identify-ghostty-surface" "$runtime_dir/libexec/"
cp "$repo_dir/libexec/restore-codex-sessions" "$runtime_dir/libexec/"
cp "$repo_dir"/applescript/*.applescript "$runtime_dir/applescript/"
cp "$repo_dir/shell/ghostx.zsh" "$runtime_dir/shell/"
chmod 755 \
  "$runtime_dir/libexec/bind-codex-session" \
  "$runtime_dir/libexec/identify-ghostty-surface" \
  "$runtime_dir/libexec/restore-codex-sessions"
chmod 644 "$runtime_dir"/applescript/*.applescript "$runtime_dir/shell/ghostx.zsh"

mkdir -p "$(dirname -- "$ghostty_config")"
touch "$ghostty_config"
if ! grep -Fq '# >>> ghostx >>>' "$ghostty_config"; then
  if [ -s "$ghostty_config" ] && [ "$(tail -c 1 "$ghostty_config" | wc -l | tr -d ' ')" -eq 0 ]; then
    printf '\n' >>"$ghostty_config"
  fi
  {
    printf '# >>> ghostx >>>\n'
    cat "$repo_dir/config/ghostty.conf"
    printf '# <<< ghostx <<<\n'
  } >>"$ghostty_config"
fi

mkdir -p "$codex_dir"
if [ ! -f "$hooks_file" ]; then
  printf '%s\n' '{"hooks":{}}' >"$hooks_file"
fi
hooks_mode=$(stat -f '%Lp' "$hooks_file")
/usr/bin/plutil -convert json -o - "$hooks_file" >/dev/null

ghostx_hook_present=0
ghostx_hook_index=""
if /usr/bin/plutil -type hooks.SessionStart "$hooks_file" >/dev/null 2>&1; then
  session_start_count=$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$hooks_file" 2>/dev/null || printf '0')
  session_start_index=0
  while [ "$session_start_index" -lt "$session_start_count" ]; do
    installed_command=$(
      /usr/bin/plutil -extract "hooks.SessionStart.$session_start_index.hooks.0.command" raw -o - "$hooks_file" 2>/dev/null || true
    )
    case "$installed_command" in
      *ghostx/runtime/libexec/bind-codex-session*)
        ghostx_hook_present=1
        ghostx_hook_index=$session_start_index
        break
        ;;
    esac
    session_start_index=$((session_start_index + 1))
  done
fi

if [ "$ghostx_hook_present" -eq 0 ]; then
  tmp_hooks=$(mktemp "$codex_dir/hooks.XXXXXX")
  cp "$hooks_file" "$tmp_hooks"

  if ! /usr/bin/plutil -type hooks "$tmp_hooks" >/dev/null 2>&1; then
    /usr/bin/plutil -insert hooks -dictionary "$tmp_hooks"
  fi
  if ! /usr/bin/plutil -type hooks.SessionStart "$tmp_hooks" >/dev/null 2>&1; then
    /usr/bin/plutil -insert hooks.SessionStart -array "$tmp_hooks"
  fi

  hook_index=$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$tmp_hooks")
  hook_path="hooks.SessionStart.$hook_index"
  /usr/bin/plutil -insert "$hook_path" -dictionary "$tmp_hooks"
  /usr/bin/plutil -insert "$hook_path.matcher" -string 'startup|resume|clear' "$tmp_hooks"
  /usr/bin/plutil -insert "$hook_path.hooks" -array "$tmp_hooks"
  /usr/bin/plutil -insert "$hook_path.hooks.0" -dictionary "$tmp_hooks"
  /usr/bin/plutil -insert "$hook_path.hooks.0.type" -string 'command' "$tmp_hooks"
  /usr/bin/plutil -insert "$hook_path.hooks.0.command" -string "$runtime_dir/libexec/bind-codex-session" "$tmp_hooks"
  /usr/bin/plutil -insert "$hook_path.hooks.0.timeout" -integer 10 "$tmp_hooks"
  /usr/bin/plutil -insert "$hook_path.hooks.0.statusMessage" -string 'Binding this Codex session to its terminal' "$tmp_hooks"
  /usr/bin/plutil -convert json -r "$tmp_hooks"
  mv "$tmp_hooks" "$hooks_file"
  chmod "$hooks_mode" "$hooks_file"
else
  installed_timeout=$(
    /usr/bin/plutil -extract "hooks.SessionStart.$ghostx_hook_index.hooks.0.timeout" raw -o - "$hooks_file" 2>/dev/null || true
  )
  if [ "$installed_timeout" != "10" ]; then
    tmp_hooks=$(mktemp "$codex_dir/hooks.XXXXXX")
    cp "$hooks_file" "$tmp_hooks"
    if /usr/bin/plutil -type "hooks.SessionStart.$ghostx_hook_index.hooks.0.timeout" "$tmp_hooks" >/dev/null 2>&1; then
      /usr/bin/plutil -replace "hooks.SessionStart.$ghostx_hook_index.hooks.0.timeout" -integer 10 "$tmp_hooks"
    else
      /usr/bin/plutil -insert "hooks.SessionStart.$ghostx_hook_index.hooks.0.timeout" -integer 10 "$tmp_hooks"
    fi
    /usr/bin/plutil -convert json -r "$tmp_hooks"
    mv "$tmp_hooks" "$hooks_file"
    chmod "$hooks_mode" "$hooks_file"
  fi
fi

touch "$zshrc"
if ! grep -Fq '# >>> ghostx >>>' "$zshrc"; then
  if [ -s "$zshrc" ] && [ "$(tail -c 1 "$zshrc" | wc -l | tr -d ' ')" -eq 0 ]; then
    printf '\n' >>"$zshrc"
  fi
  cat >>"$zshrc" <<'EOF'
# >>> ghostx >>>
_ghostx_integration="${XDG_DATA_HOME:-$HOME/.local/share}/ghostx/runtime/shell/ghostx.zsh"
[[ -r "$_ghostx_integration" ]] && source "$_ghostx_integration"
unset _ghostx_integration
# <<< ghostx <<<
EOF
fi

# Installing into an already-running Ghostty process must not make the next
# newly opened shell replay commands into terminals that are currently in use.
# Mark only the current process set as handled; a future Ghostty launch gets a
# different process identity and performs the normal restoration.
instance_id=$(ghostty_instance_id)
if [ -n "$instance_id" ]; then
  mkdir -p "$state_dir/run"
  printf '%s\n' "$(date +%s):installed" >"$state_dir/run/restored-$instance_id"
fi

printf '%s\n' "Ghostx installed."
printf '%s\n' "Next: open a new Ghostty shell (or run exec zsh), then start or resume Codex."
printf '%s\n' "Open /hooks once and trust the Ghostx SessionStart hook if it is pending review."
