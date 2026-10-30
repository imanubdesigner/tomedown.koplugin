#!/usr/bin/env bash
# Push main to GitHub, then mirror that commit to Codeberg with the links
# that name a host rewritten for the other forge.
#
# The mirror commit is built from the tree that is already committed, so the
# working tree is never switched and nothing is added to the history of main:
#
#   tools/publish.sh
#
# GitHub is the canonical home; main tracks origin/main. The Codeberg branch
# keeps one commit of its own per publication, because README.md and
# TUTORIAL.md are replaced by their .codeberg.md copies there.
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
git fetch --quiet codeberg

work=$(mktemp -d)
index=$(mktemp)
trap 'rm -rf "$work" "$index"' EXIT

# the mirrored documents, built from the files that are about to be pushed
lua tools/readme_variant.lua README.md > "$work/README.md"
lua tools/readme_variant.lua TUTORIAL.md > "$work/TUTORIAL.md"

for doc in README TUTORIAL; do
    if ! git show "main:$doc.codeberg.md" | diff -q - "$work/$doc.md" > /dev/null; then
        fail "$doc.codeberg.md is stale, regenerate it and commit it first"
    fi
done

git push --quiet origin main
printf 'github:  %s\n' "$(git rev-parse --short main)"

# the tree of main with the two documents swapped for their copies
GIT_INDEX_FILE=$index git read-tree main
for doc in README TUTORIAL; do
    blob=$(git hash-object -w "$work/$doc.md")
    GIT_INDEX_FILE=$index git update-index --add --cacheinfo "100644,$blob,$doc.md"
done
tree=$(GIT_INDEX_FILE=$index git write-tree)

parent=$(git rev-parse codeberg/main)
if [ "$(git rev-parse "$parent^{tree}")" = "$tree" ]; then
    printf 'codeberg: already up to date (%s)\n' "$(git rev-parse --short "$parent")"
    exit 0
fi

mirror=$(printf 'chore: sync Codeberg mirror from GitHub\n\nMirror of %s on origin/main. Only the links that name a host are\nrewritten, in README.md and TUTORIAL.md.\n' \
    "$(git rev-parse --short main)" | git commit-tree "$tree" -p "$parent" -F -)
git push --quiet codeberg "$mirror:refs/heads/main"
printf 'codeberg: %s\n' "$(git rev-parse --short "$mirror")"
