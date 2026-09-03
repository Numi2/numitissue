#!/bin/zsh
set -u -o pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"

# This is a manually controlled evidence run.  The Python runner performs the
# source audit before creating output, executes the host preflight, records
# every required command, and never issues production authorization.
exec python3 "$repo_root/Tools/phase3/phase3_evidence.py" run \
    --root "$repo_root" \
    "$@"
