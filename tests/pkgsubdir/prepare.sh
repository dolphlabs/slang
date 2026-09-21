repo=/tmp/sl_pkgsubdir_repo
cache=/tmp/sl_pkgsubdir_cache
rm -rf "$repo" "$cache"
mkdir -p "$repo/src" "$repo/examples" "$cache"
cp tests/pkgsubdir/ext/src/*.sl "$repo/src/"
cp tests/pkgsubdir/ext/examples/broken.sl "$repo/examples/"
(cd "$repo" && git init -q && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m t &&
    git tag v1)
cat > tests/pkgsubdir/slang.project <<EOF2
name pkgsubdir
version 0.1.0
pkg demo git $repo tag v1 dir src
EOF2
export SLANG_CACHE="$cache"
./slangc get tests/pkgsubdir/main.sl >/dev/null
