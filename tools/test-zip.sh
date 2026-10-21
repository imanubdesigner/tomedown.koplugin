#!/usr/bin/env bash
# Build the test zip for the current branch and drop it in the folder where
# Manuel extracts it for local testing. git archive reads committed trees
# only: every test zip is made of commits, never of uncommitted work.
set -euo pipefail
branch="$(git rev-parse --abbrev-ref HEAD)"
out="$HOME/Documents/Tomedown-Bidirectional/tomedown.zip"
mkdir -p "$(dirname "$out")"
git archive --format=zip --prefix=tomedown.koplugin/ "$branch" -o "$out"
echo "wrote $out ($branch, $(du -h "$out" | cut -f1))"
