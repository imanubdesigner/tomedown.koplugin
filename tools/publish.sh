#!/usr/bin/env bash
# Push main and the tags to both forges.
#
# origin carries two push URLs, GitHub first and the Codeberg mirror second,
# so one command reaches both. The two repositories keep the same history and
# the same commit hashes: Codeberg is a backup, not a fork with commits of
# its own.
#
#   tools/publish.sh
#
# The release zips are not part of git. They are uploaded as real assets on
# both forges, one per release.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    printf 'publish: %s\n' "$1" >&2
    exit 1
}

if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    fail "switch to main first"
fi
if [ -n "$(git status --porcelain)" ]; then
    fail "the working tree has changes, commit or stash them first"
fi

git fetch --quiet origin
git push --quiet origin main
git push --quiet origin --tags

printf 'main: %s\nlatest tag: %s\n' \
    "$(git rev-parse --short main)" \
    "$(git describe --tags --abbrev=0)"
