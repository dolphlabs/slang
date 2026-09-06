leaf=/tmp/sl_pkgtrans_leaf
mid=/tmp/sl_pkgtrans_mid
cache=/tmp/sl_pkgtrans_cache
rm -rf "$leaf" "$mid" "$cache"
mkdir -p "$leaf" "$mid" "$cache"
cp tests/pkgtrans/leaf/*.sl "$leaf/"
(cd "$leaf" && git init -q && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m t &&
    git tag v1)
cp tests/pkgtrans/mid/*.sl "$mid/"
cat > "$mid/slang.project" <<EOF
name mid
version 0.1.0
pkg leaf git $leaf tag v1
EOF
(cd "$mid" && git init -q && git add . &&
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m t &&
    git tag v1)
cat > tests/pkgtrans/slang.project <<EOF
name pkgtrans
version 0.1.0
pkg mid git $mid tag v1
EOF
export SLANG_CACHE="$cache"
./slangc get tests/pkgtrans/main.sl >/dev/null
grep -q '^leaf ' tests/pkgtrans/slang.lock
grep -q '^mid ' tests/pkgtrans/slang.lock
