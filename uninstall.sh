#!/bin/sh

set -eu

data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
runtime_dir="$data_home/ghostx/runtime"
codex_dir=${CODEX_HOME:-"$HOME/.codex"}
hooks_file="$codex_dir/hooks.json"
zshrc=${ZDOTDIR:-$HOME}/.zshrc
ghostty_config=${GHOSTX_GHOSTTY_CONFIG:-"$HOME/Library/Application Support/com.mitchellh.ghostty/config"}

remove_marked_block() {
  file=$1
  [ -f "$file" ] || return 0
  original_mode=$(stat -f '%Lp' "$file")
  tmp_file=$(mktemp "$(dirname -- "$file")/ghostx-uninstall.XXXXXX")
  awk '
    $0 == "# >>> ghostx >>>" { skipping = 1; next }
    $0 == "# <<< ghostx <<<" { skipping = 0; next }
    !skipping { print }
  ' "$file" >"$tmp_file"
  chmod "$original_mode" "$tmp_file"
  mv "$tmp_file" "$file"
}

remove_marked_block "$ghostty_config"
remove_marked_block "$zshrc"

if [ -f "$hooks_file" ] && /usr/bin/plutil -convert json -o - "$hooks_file" >/dev/null 2>&1; then
  count=$(/usr/bin/plutil -extract hooks.SessionStart raw -o - "$hooks_file" 2>/dev/null || printf '0')
  index=0
  while [ "$index" -lt "$count" ]; do
    command_value=$(
      /usr/bin/plutil -extract "hooks.SessionStart.$index.hooks.0.command" raw -o - "$hooks_file" 2>/dev/null || true
    )
    case "$command_value" in
      *ghostx/runtime/libexec/bind-codex-session*)
        /usr/bin/plutil -remove "hooks.SessionStart.$index" "$hooks_file"
        count=$((count - 1))
        ;;
      *) index=$((index + 1)) ;;
    esac
  done
  /usr/bin/plutil -convert json -r "$hooks_file"
fi

if [ -d "$runtime_dir" ]; then
  find "$runtime_dir" -type f -delete
  find "$runtime_dir" -depth -type d -empty -delete
fi

printf '%s\n' "Ghostx integration removed. State was kept under ${XDG_STATE_HOME:-$HOME/.local/state}/ghostx."
