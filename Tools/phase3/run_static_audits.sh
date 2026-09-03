#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
exec python3 "$repo_root/Tools/phase3/static_audit.py" --root "$repo_root" "$@"
