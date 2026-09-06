repo=/tmp/sl_pkgpin_repo
cache=/tmp/sl_pkgpin_cache
rm -rf "$repo" "$cache"
mkdir -p "$repo" "$cache"
cp tests/pkgpin/ext/*.sl "$repo/"
(cd "$repo" && git init -q && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m t &&
    git tag v1)
cat > tests/pkgpin/slang.project <<EOF
name pkgpin
version 0.1.0
pkg demo git $repo tag v1
EOF
export SLANG_CACHE="$cache"
./slangc get tests/pkgpin/main.sl >/dev/null
