#!/bin/sh
# Builds the deployable site into site/: the documentation that the slang
# repository generates into docs/ on its main branch, with this homepage
# laid over it at /. The docs keep every other path, including /index.md,
# the Markdown twin agents read for the home page.
#
#   npm run assemble                              docs from GitHub, main
#   SLANG_DOCS_REF=dev npm run assemble           another branch or tag
#   SLANG_DOCS_DIR=../slang/docs npm run assemble a local checkout, offline

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/site"
REPO="${SLANG_REPO:-https://github.com/dolphlabs/slang.git}"
REF="${SLANG_DOCS_REF:-main}"

(cd "$ROOT" && npm run --silent build)

rm -rf "$OUT"
mkdir -p "$OUT"

if [ -n "${SLANG_DOCS_DIR:-}" ]; then
    cp -R "$SLANG_DOCS_DIR/." "$OUT/"
else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    # Only docs/ is checked out, and only its blobs are downloaded: the
    # language's source and history never leave GitHub.
    git -C "$tmp" init -q
    git -C "$tmp" remote add origin "$REPO"
    git -C "$tmp" sparse-checkout set --no-cone /docs/
    git -C "$tmp" fetch -q --depth 1 --filter=blob:none origin "$REF"
    git -C "$tmp" checkout -q FETCH_HEAD
    cp -R "$tmp/docs/." "$OUT/"
fi

for f in index.html llms.txt api.json guide/index.html; do
    if [ ! -f "$OUT/$f" ]; then
        echo "assemble: the docs have no $f; is $REF a branch with a built docs/?" >&2
        exit 1
    fi
done

cp -R "$ROOT/dist/." "$OUT/"
cat "$ROOT/deploy/_headers" >>"$OUT/_headers"

echo "assemble: site/ ready ($(find "$OUT" -type f | wc -l | tr -d ' ') files, docs from ${SLANG_DOCS_DIR:-$REF})"
