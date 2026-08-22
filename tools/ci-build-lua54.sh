#!/bin/sh
set -eu

# Build the pinned official Lua 5.4 with a shared runtime for the CI smoke
# gate. Distribution interpreters statically link the Lua core (ldd shows no
# liblua), which hides the runtime from the collision/relink fixtures in
# test/production_edges.lua. The recipe mirrors the release matrix builder.

VERSION=5.4.8
SHA256=4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
PREFIX=${LUAI_CI_LUA_PREFIX:-$HOME/luai-lua}
WORK=${LUAI_CI_WORK:-/tmp/luai-ci-lua}
ARCHIVE=$WORK/lua-$VERSION.tar.gz
SOURCE=$WORK/lua-$VERSION

mkdir -p "$WORK"
ARCHIVE_PART=$ARCHIVE.part.$$
rm -f "$ARCHIVE_PART"
trap 'rm -f "$ARCHIVE_PART"' EXIT HUP INT TERM
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    --connect-timeout 30 --max-time 240 \
    "https://www.lua.org/ftp/lua-$VERSION.tar.gz" -o "$ARCHIVE_PART"
if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$SHA256" "$ARCHIVE_PART" | sha256sum -c - >/dev/null
else
    actual=$(shasum -a 256 "$ARCHIVE_PART" | awk '{ print $1 }')
    [ "$actual" = "$SHA256" ]
fi
mv -f "$ARCHIVE_PART" "$ARCHIVE"
trap - EXIT HUP INT TERM
rm -rf "$SOURCE" "$PREFIX"
tar -xzf "$ARCHIVE" -C "$WORK"

make -C "$SOURCE/src" all \
    MYCFLAGS='-fPIC -DLUA_USE_POSIX -DLUA_USE_DLOPEN' \
    MYLIBS='-Wl,-E -ldl'
make -C "$SOURCE" INSTALL_TOP="$PREFIX" install

# The stock Makefile installs only the static archive; relink it into the
# ABI-versioned shared runtime the fixtures expect.
members=$(ar t "$SOURCE/src/liblua.a")
if [ -z "$members" ]; then
    echo "empty liblua archive member list" >&2
    exit 1
fi
# Archive members are validated above; intentional word splitting.
# shellcheck disable=SC2086
(cd "$SOURCE/src" && cc -shared -Wl,-soname,liblua.so.5.4 \
    -o "$PREFIX/lib/liblua.so.5.4" $members -lm -ldl)
ln -sf liblua.so.5.4 "$PREFIX/lib/liblua.so"

mkdir -p "$PREFIX/lib/pkgconfig"
{
    printf 'prefix=%s\n' "$PREFIX"
    printf '%s\n' 'exec_prefix=${prefix}'
    printf '%s\n' 'libdir=${exec_prefix}/lib'
    printf '%s\n' 'includedir=${prefix}/include'
    printf '\nName: Lua\nDescription: Official Lua %s CI runtime\n' "$VERSION"
    printf 'Version: %s\n' "$VERSION"
    printf '%s\n' 'Libs: -L${libdir} -llua -lm'
    printf '%s\n' 'Libs.private: -ldl'
    printf '%s\n' 'Cflags: -I${includedir}'
} > "$PREFIX/lib/pkgconfig/lua.pc"

LD_LIBRARY_PATH="$PREFIX/lib" "$PREFIX/bin/lua" -e \
    "assert(_VERSION == 'Lua 5.4')"
printf 'built %s at %s\n' "$VERSION" "$PREFIX"
