#!/usr/bin/env bash
# Build the release zip from a committed tree.
#
# The archive is an allowlist, not "everything in the folder": only the
# files KOReader needs at runtime and the logo used by the About popup.
# The docs, the tests, the menu screenshots and the repository banners
# stay out. The script checks the exact contents of the archive and the
# Lua syntax before printing the sha256 that goes with the release.
#
#   tools/release-zip.sh            HEAD
#   tools/release-zip.sh 1.2.0      a branch, tag or commit
#   tools/release-zip.sh v1.2.0
set -euo pipefail

case "${1:-}" in
    -h|--help)
        echo "usage: $0 [ref]"
        echo "builds tomedown.koplugin-v<version>.zip from a commit (default HEAD)"
        exit 0
        ;;
esac

ref="${1:-HEAD}"

cd "$(git rev-parse --show-toplevel)"

if ! git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
    echo "error: not a commit: $ref" >&2
    exit 1
fi

# a release is a commit: never package a half-finished working tree
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "error: the working tree has uncommitted changes; commit them first" >&2
    exit 1
fi

version=$(git show "${ref}:_meta.lua" \
    | sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' \
    | head -n 1)
if [ -z "$version" ]; then
    echo "error: no version in ${ref}:_meta.lua" >&2
    exit 1
fi

# the complete allowlist: anything else, even a new module at the root,
# has to be added here on purpose
mapfile -t files < <(
    git ls-tree -r --name-only "$ref" | awk '
        $0 == "LICENSE" || $0 == "_meta.lua" || $0 == "assets/logo.png" \
            || $0 == "main.lua" { print; next }
        /^languages\/[^\/]+\.po$/ { print; next }
        /^tomedown_[^\/]+\.lua$/ { print; next }
    ' | LC_ALL=C sort
)

for required in LICENSE _meta.lua assets/logo.png main.lua; do
    found=0
    for file in "${files[@]}"; do
        if [ "$file" = "$required" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "error: ${required} is missing from the allowlist" >&2
        exit 1
    fi
done
if [ "${#files[@]}" -eq 0 ]; then
    echo "error: the allowlist is empty" >&2
    exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo "error: unzip is needed to check the archive contents" >&2
    exit 1
fi
if ! command -v luac5.1 >/dev/null 2>&1; then
    echo "error: luac5.1 is needed to check the Lua that runs on the Kindle" >&2
    exit 1
fi

out_dir="${TOMEDOWN_RELEASE_DIR:-$HOME/Documents/Tomedown-Bidirectional}"
out="$out_dir/tomedown.koplugin-v${version}.zip"
mkdir -p "$out_dir"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/release.zip"

git archive --format=zip --prefix=tomedown.koplugin/ "$ref" \
    -o "$archive" -- "${files[@]}"

# exact contents: no directory entries, no extra file, no docs, no banners
mapfile -t actual < <(
    unzip -Z1 "$archive" \
        | grep -v '/$' \
        | sed -n 's#^tomedown\.koplugin/##p' \
        | LC_ALL=C sort
)
if [ "${#actual[@]}" -ne "${#files[@]}" ]; then
    echo "error: the archive has ${#actual[@]} files, the allowlist has ${#files[@]}" >&2
    printf '  %s\n' "${actual[@]}" >&2
    exit 1
fi
for i in "${!files[@]}"; do
    if [ "${actual[$i]}" != "${files[$i]}" ]; then
        echo "error: the archive contents differ from the allowlist" >&2
        echo "  expected: ${files[$i]}" >&2
        echo "  in zip:   ${actual[$i]}" >&2
        exit 1
    fi
done

unzip -q "$archive" -d "$tmp/check"
while IFS= read -r -d '' file; do
    luac5.1 -p "$file"
done < <(find "$tmp/check" -type f -name '*.lua' -print0)

mv "$archive" "$out"

echo "wrote $out"
echo "files ${#files[@]}"
sha256sum "$out"
