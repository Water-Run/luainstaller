#!/bin/sh
set -eu

# Native POSIX release matrix for the final official release of every Lua 5.x ABI.
SOURCE_CACHE=${SOURCE_CACHE:-/tmp/luainstaller-source-cache}
WORK_ROOT=${WORK_ROOT:-/tmp/luainstaller-lua-matrix}
EVIDENCE_DIR=${EVIDENCE_DIR:-/tmp/luainstaller-lua-evidence}
HOST_LABEL=${HOST_LABEL:-$(uname -n | tr -c 'A-Za-z0-9._-' '-')}
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LUAROCKS_VERSION=3.13.0
LUAROCKS_TARBALL=luarocks-$LUAROCKS_VERSION.tar.gz
LUAROCKS_SHA256=245bf6ec560c042cb8948e3d661189292587c5949104677f1eecddc54dbe7e37
VERSIONS='5.1.5:2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333
5.2.4:b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b
5.3.6:fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60
5.4.8:4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
5.5.0:57ccc32bbbd005cab75bcc52444052535af691789dba2b9016d5c50640d68b3d'

require_no_symlink_ancestors() {
    candidate=$1
    remainder=${candidate#/tmp/}
    current=/tmp
    old_ifs=$IFS
    IFS=/
    set -- $remainder
    IFS=$old_ifs
    for component do
        current=$current/$component
        if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
            echo "unsafe symlink or non-directory ancestor: $current" >&2
            exit 2
        fi
        [ -e "$current" ] || break
    done
}

require_safe_tmp_path() {
    case "$1" in
        /tmp/luainstaller-?*) ;;
        *) echo "unsafe temporary path: $1" >&2; exit 2 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9._/-]*|*'/../'*|*'/..'|*'/./'*|*'/.'|*'//'*)
            echo "unsafe temporary path: $1" >&2
            exit 2
            ;;
    esac
    require_no_symlink_ancestors "$1"
}

stage_source() {
    name=$1
    url=$2
    expected=$3
    destination=$SOURCE_CACHE/$name
    if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
        echo "unsafe source-cache entry: $destination" >&2
        exit 2
    fi
    if [ -f "$destination" ] \
        && ! printf '%s  %s\n' "$expected" "$destination" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$destination"
    fi
    if [ ! -f "$destination" ]; then
        part=$destination.part.$$
        rm -f "$part"
        trap 'rm -f "$part"' EXIT HUP INT TERM
        curl -fL --connect-timeout 20 --max-time 240 -o "$part" "$url"
        printf '%s  %s\n' "$expected" "$part" | sha256sum -c - >/dev/null
        mv "$part" "$destination"
        trap - EXIT HUP INT TERM
    fi
}

for path in "$SOURCE_CACHE" "$WORK_ROOT" "$EVIDENCE_DIR"; do
    require_safe_tmp_path "$path"
done
case "$HOST_LABEL" in
    ''|*[!A-Za-z0-9._-]*) echo "unsafe host label: $HOST_LABEL" >&2; exit 2 ;;
esac
for command in ar cc curl git grep make readlink sha256sum tar; do
    command -v "$command" >/dev/null 2>&1 || { echo "missing command: $command" >&2; exit 1; }
done
if [ "$(uname -s)" = Linux ]; then
    command -v readelf >/dev/null 2>&1 || { echo "missing command: readelf" >&2; exit 1; }
fi

umask 077
mkdir -p "$SOURCE_CACHE" "$WORK_ROOT" "$EVIDENCE_DIR"
chmod 700 "$SOURCE_CACHE" "$WORK_ROOT" "$EVIDENCE_DIR"
stage_source "$LUAROCKS_TARBALL" \
    "https://luarocks.org/releases/$LUAROCKS_TARBALL" "$LUAROCKS_SHA256"
printf '%s\n' "$VERSIONS" | while IFS=: read -r version expected; do
    stage_source "lua-$version.tar.gz" "https://www.lua.org/ftp/lua-$version.tar.gz" "$expected"
done

build_lua() {
    version=$1
    prefix=$WORK_ROOT/lua-$version
    lua=$prefix/bin/lua
    abi=${version%.*}
    complete=0
    if [ -x "$lua" ] && [ "$("$lua" -e 'io.write(_VERSION)')" = "Lua $abi" ]; then
        complete=1
    fi
    if [ "$(uname -s)" = Linux ] && {
        [ ! -f "$prefix/lib/liblua.so.$abi" ] \
            || [ ! -L "$prefix/lib/liblua.so" ] \
            || [ "$(readlink "$prefix/lib/liblua.so" 2>/dev/null || true)" != "liblua.so.$abi" ];
    }; then
        complete=0
    fi
    if [ "$complete" -eq 1 ]; then
        printf '%s\n' "$prefix"
        return
    fi
    source_dir=$WORK_ROOT/source-lua-$version
    rm -rf "$prefix" "$source_dir"
    mkdir -p "$source_dir"
    tar -xzf "$SOURCE_CACHE/lua-$version.tar.gz" -C "$source_dir"
    source_dir=$source_dir/lua-$version
    case "$(uname -s):$version" in
        Linux:*)
            make -C "$source_dir/src" all \
                MYCFLAGS='-fPIC -DLUA_USE_POSIX -DLUA_USE_DLOPEN' \
                MYLIBS='-Wl,-E -ldl' >&2
            ;;
        Darwin:*)
            make -C "$source_dir" macosx MYCFLAGS=-fPIC >&2
            ;;
        *) echo "unsupported POSIX build host: $(uname -s)" >&2; return 1 ;;
    esac
    make -C "$source_dir" INSTALL_TOP="$prefix" install >&2
    if [ "$(uname -s)" = Linux ]; then
        archive=$source_dir/src/liblua.a
        runtime=$prefix/lib/liblua.so.$abi
        members=$(ar t "$archive")
        if [ -z "$members" ] || printf '%s\n' "$members" \
            | grep -Ev '^[A-Za-z0-9_.-]+$' | grep . >/dev/null; then
            echo "unsafe or empty liblua archive member list" >&2
            return 1
        fi
        # Archive members are source-pinned and validated above; intentional splitting.
        # shellcheck disable=SC2086
        (cd "$source_dir/src" && cc -shared -Wl,-soname,"liblua.so.$abi" \
            -o "$runtime" $members -lm -ldl)
        rm -f "$prefix/lib/liblua.so.${version%%.*}" "$prefix/lib/liblua.so"
        ln -s "liblua.so.$abi" "$prefix/lib/liblua.so.${version%%.*}"
        ln -s "liblua.so.$abi" "$prefix/lib/liblua.so"
        readelf -d "$runtime" | grep -F "Library soname: [liblua.so.$abi]" >/dev/null
        LD_LIBRARY_PATH="$prefix/lib" "$lua" -e \
            "assert(_VERSION == 'Lua $abi')"
    fi
    test "$("$lua" -e 'io.write(_VERSION)')" = "Lua ${version%.*}"
    printf '%s\n' "$prefix"
}

build_luarocks() {
    version=$1
    lua_prefix=$2
    prefix=$WORK_ROOT/luarocks-$version
    command=$prefix/bin/luarocks
    if [ -x "$command" ]; then
        printf '%s\n' "$prefix"
        return
    fi
    source_dir=$WORK_ROOT/source-luarocks-$version
    rm -rf "$prefix" "$source_dir"
    mkdir -p "$source_dir"
    tar -xzf "$SOURCE_CACHE/$LUAROCKS_TARBALL" -C "$source_dir"
    source_dir=$source_dir/luarocks-$LUAROCKS_VERSION
    (cd "$source_dir" && ./configure --prefix="$prefix" --with-lua="$lua_prefix") >&2
    make -C "$source_dir" >&2
    make -C "$source_dir" install >&2
    "$command" --version >/dev/null
    printf '%s\n' "$prefix"
}

run_version() {
    version=$1
    lua_prefix=$(build_lua "$version")
    luarocks_prefix=$(build_luarocks "$version" "$lua_prefix")
    lua=$lua_prefix/bin/lua
    luarocks=$luarocks_prefix/bin/luarocks
    expected="Lua ${version%.*}"
    test "$("$lua" -e 'io.write(_VERSION)')" = "$expected"
    if [ "$(uname -s)" = Linux ]; then
        abi=${version%.*}
        test -f "$lua_prefix/lib/liblua.so.$abi"
        test -L "$lua_prefix/lib/liblua.so"
        test "$(readlink "$lua_prefix/lib/liblua.so")" = "liblua.so.$abi"
    fi
    export PATH="$luarocks_prefix/bin:$lua_prefix/bin:/usr/bin:/bin"
    export LUAI_TEST_LUA="$lua"
    export LUAI_LUA_PREFIX="$lua_prefix"
    export LUA_PATH=''
    export LUA_CPATH=''
    cd "$PROJECT_ROOT"
    find src -type f -name '*.lua' -print | while IFS= read -r file; do
        LUAI_SYNTAX_FILE="$file" "$lua" \
            -e 'assert(loadfile(os.getenv("LUAI_SYNTAX_FILE")))'
    done
    "$lua" test/lua_abi.lua
    "$lua" test/version_contract.lua
    "$lua" test/cli_split_smoke.lua
    "$lua" test/contract_docs.lua
    "$luarocks" lint luainstaller-1.0.0-1.rockspec
    "$lua" test/luarocks_install.lua
    "$lua" test/toolchain_native.lua
    "$lua" test/native_bundle.lua
    "$lua" test/onefile_compile_native.lua
    "$lua" test/native_onefile.lua
    "$lua" test/onefile_lifecycle.lua
    "$lua" test/build_interruption.lua
    if [ "${RUN_FULL_SUITE:-0}" = 1 ] && [ "$version" = 5.5.0 ]; then
        "$lua" test/production_edges.lua
        "$lua" test/smoke_all.lua
    fi
    printf 'PASS host=%s lua=%s abi=%s\n' "$HOST_LABEL" "$version" "$expected"
}

printf '%s\n' "$VERSIONS" | while IFS=: read -r version _; do
    log=$EVIDENCE_DIR/$HOST_LABEL-lua-$version.log
    set +e
    (set -e; run_version "$version") >"$log" 2>&1
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        tail -n 1 "$log"
    else
        cat "$log" >&2
        exit "$status"
    fi
done
