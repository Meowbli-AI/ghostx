#!/bin/sh

set -eu

script_name=$(basename -- "$1")
shift

case "$script_name" in
  find-terminal-by-title.applescript)
    printf '%s\n' "11111111-2222-3333-4444-555555555555"
    ;;
  count-terminals.applescript)
    printf '%s\n' "2"
    ;;
  restore-surface.applescript)
    printf '%s\t%s\n' "$1" "$2" >>"$GHOSTX_MOCK_LOG"
    printf '%s\n' "restored"
    ;;
  *)
    printf '%s\n' "unexpected mock script: $script_name" >&2
    exit 1
    ;;
esac

