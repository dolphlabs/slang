#!/bin/sh
# Prints a release's notes as Markdown: the annotated tag's message (what
# changed, written when the tag is made), then how to install this version
# and the SHA-256 of every tarball. Used by .github/workflows/release.yml;
# run it locally to preview:
#
#     .github/release-notes.sh v0.2.1 SHA256SUMS
#
# SHA256SUMS is `sha256sum`/`shasum -a 256` output for the tarballs.
set -eu

tag="$1"
sums="$2"
version="${tag#v}"

if [ "$(git cat-file -t "refs/tags/$tag" 2>/dev/null)" != tag ]; then
    echo "release-notes: $tag is not an annotated tag" >&2
    exit 1
fi
if [ ! -s "$sums" ]; then
    echo "release-notes: $sums is missing or empty" >&2
    exit 1
fi

body=$(git tag -l --format='%(contents:body)' "$tag" |
       sed -e '/^-----BEGIN PGP SIGNATURE-----$/,$d')
if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    echo "release-notes: $tag has no message body to use as notes" >&2
    exit 1
fi

# One example tarball name, for the install snippet: the first listed.
example=$(awk 'NR == 1 { sub(/\.tar\.gz$/, "", $2); sub(/^\*/, "", $2); print $2 }' "$sums")

printf '%s\n\n' "$body"
cat <<EOF
## Install

**From a tarball** (relocatable: unpack anywhere and run in place). Pick
the one for your platform below; each was unpacked outside the source tree
and used to build and run a new project before this release was published.

\`\`\`sh
tar -xzf $example.tar.gz
./$example/bin/slangc --version     # slangc $version
\`\`\`

**From source:**

\`\`\`sh
git clone https://github.com/dolphlabs/slang && cd slang
git checkout $tag
sudo make install          # PREFIX=/usr/local, or ~/.local

slangc new hello && cd hello && slangc main.sl --run
\`\`\`

Upgrading a source install: run \`sudo make uninstall\` from the old
checkout first. \`make install\` overwrites the binary but never deletes
stale runtime files.

### Requirements

slangc compiles to C, so every platform needs a C compiler (\`cc\`).

| you import | you need |
|---|---|
| anything | a C compiler |
| \`net\` with TLS, \`crypto\`, \`httpc\` over https | OpenSSL (macOS: \`brew install openssl\`; Debian/Ubuntu: \`apt install libssl-dev\`) |
| \`sql\` | SQLite (Debian/Ubuntu: \`apt install libsqlite3-dev\`; ships with macOS) |
| \`compress\`, \`httpc\` | zlib (Debian/Ubuntu: \`apt install zlib1g-dev\`; ships with macOS) |

The Linux tarballs are built on Ubuntu 24.04 and need glibc 2.39 or later;
on an older distribution, build from source.

### SHA-256

\`\`\`
$(sed 's/ \*/  /' "$sums")
\`\`\`
EOF
