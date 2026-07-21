#!/bin/sh
set -eu

# Native POSIX release matrix for the final official release of every Lua 5.x ABI.
SOURCE_CACHE=${SOURCE_CACHE:-/tmp/luainstaller-source-cache}
WORK_ROOT=${WORK_ROOT:-/tmp/luainstaller-lua-matrix}
EVIDENCE_DIR=${EVIDENCE_DIR:-/tmp/luainstaller-lua-evidence}
HOST_LABEL=${HOST_LABEL:-$(uname -n | tr -c 'A-Za-z0-9._-' '-')}
LUAI_MATRIX_EDGE_COVERAGE_MODE=${LUAI_MATRIX_EDGE_COVERAGE_MODE:-full}
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LUAROCKS_VERSION=3.13.0
LUAROCKS_TARBALL=luarocks-$LUAROCKS_VERSION.tar.gz
LUAROCKS_SHA256=245bf6ec560c042cb8948e3d661189292587c5949104677f1eecddc54dbe7e37
LSQLITE3_ZIP=lsqlite3_v096.zip
LSQLITE3_SHA256=ecc6e7636a54f021bca5b4a01b35af06fd7a6fc8b21c4b3eccd4fdb5dd32ad82
LSQLITE3_SOURCE_MEMBER=lsqlite3_v096/lsqlite3.c
SQLITE_ZIP=sqlite-amalgamation-3530200.zip
SQLITE_SHA256=8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32
SQLITE_SOURCE_MEMBER=sqlite-amalgamation-3530200/sqlite3.c
CACHE_SCHEMA=luainstaller-posix-matrix-cache-v2
ROCK_SOURCES='lua-cjson-2.1.0.10-1.src.rock:02dea368d07753647c75bd9e6660dd4d06ff7d09956d90d5afc4c3f5b78ed187
luafilesystem-1.9.0-1.src.rock:3de68d619f6ad95a27f4728814375447d921305194b7050dee6199057c31282f
luasocket-3.1.0-1.src.rock:f4a207f50a3f99ad65def8e29c54ac9aac668b216476f7fae3fae92413398ed2
mimetypes-1.1.0-2.src.rock:2cf77e0b6575caa6aecb43c9a06f705b1e7d92c19c5da6bb2f07a10feeee9e2f
lzlib-0.4.1.53-4.src.rock:860c893fc53d0a7830a54fa64f22a2b89260ca39c9a7dcb0890f6d3029f00ca5
pegasus-1.1.0-0.src.rock:0f91f10e354183db06c0c2dfa878b97a0f75dc2777f4c971fbd44f848795f746'
ROCK_INSTALL_ORDER='lua-cjson-2.1.0.10-1.src.rock:lua-cjson:2.1.0.10-1
luafilesystem-1.9.0-1.src.rock:luafilesystem:1.9.0-1
luasocket-3.1.0-1.src.rock:luasocket:3.1.0-1
mimetypes-1.1.0-2.src.rock:mimetypes:1.1.0-2
lzlib-0.4.1.53-4.src.rock:lzlib:0.4.1.53-4
pegasus-1.1.0-0.src.rock:pegasus:1.1.0-0'
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
    # shellcheck disable=SC2086 # The validated path is intentionally split on '/'.
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

require_owned_private_root() {
    root=$1
    if [ -L "$root" ] || [ ! -d "$root" ]; then
        echo "temporary root is not a real directory: $root" >&2
        exit 2
    fi
    # shellcheck disable=SC2012 # Numeric ls output is portable across Linux and macOS.
    owner=$(LC_ALL=C ls -dn "$root" | awk '{ print $3 }')
    if [ "$owner" != "$(id -u)" ]; then
        echo "temporary root is not owned by the current user: $root" >&2
        exit 2
    fi
    chmod 700 "$root"
}

owned_regular_file() {
    candidate=$1
    # shellcheck disable=SC2012 # Numeric ls output is portable across Linux and macOS.
    [ -f "$candidate" ] && [ ! -L "$candidate" ] \
        && [ "$(LC_ALL=C ls -dn "$candidate" | awk '{ print $3 }')" = "$(id -u)" ]
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        echo "missing SHA-256 command: install sha256sum or shasum" >&2
        return 1
    fi
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{ print $1 }'
    else
        echo "missing SHA-256 command: install sha256sum or shasum" >&2
        return 1
    fi
}

lua_pc_version() {
    awk '
/^Version:[[:space:]]*/ {
    value = $0
    sub(/^Version:[[:space:]]*/, "", value)
    print value
    exit
}
' "$1"
}

verify_sha256() {
    expected=$1
    candidate=$2
    actual=$(sha256_file "$candidate") || return 1
    if [ "$actual" != "$expected" ]; then
        echo "SHA-256 mismatch for $candidate" >&2
        return 1
    fi
}

cache_marker_matches() {
    marker=$1
    expected=$2
    owned_regular_file "$marker" \
        && [ "$(cat "$marker")" = "$expected" ]
}

write_cache_marker() {
    marker=$1
    value=$2
    temporary=$marker.tmp.$$
    rm -f "$temporary"
    printf '%s\n' "$value" >"$temporary"
    mv "$temporary" "$marker"
}

exact_lua_release() {
    lua_command=$1
    release=$2
    banner=$("$lua_command" -v 2>&1) || return 1
    case "$banner" in
        "Lua $release"|"Lua $release "*) return 0 ;;
        *) return 1 ;;
    esac
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
    if [ -f "$destination" ] && ! owned_regular_file "$destination"; then
        echo "source-cache entry is not owned by the current user: $destination" >&2
        exit 2
    fi
    if [ -f "$destination" ] && ! verify_sha256 "$expected" "$destination"; then
        rm -f "$destination"
    fi
    if [ ! -f "$destination" ]; then
        part=$destination.part.$$
        rm -f "$part"
        trap 'rm -f "$part"' EXIT HUP INT TERM
        curl -fL --connect-timeout 20 --max-time 240 -o "$part" "$url"
        verify_sha256 "$expected" "$part"
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
case "$LUAI_MATRIX_EDGE_COVERAGE_MODE" in
    full|available) ;;
    *)
        echo "invalid LUAI_MATRIX_EDGE_COVERAGE_MODE: $LUAI_MATRIX_EDGE_COVERAGE_MODE" >&2
        exit 2
        ;;
esac
for command in ar awk cat cc chmod curl find git grep id ls make readlink tar unzip; do
    command -v "$command" >/dev/null 2>&1 || { echo "missing command: $command" >&2; exit 1; }
done
sha256_file "$0" >/dev/null
if [ "$(uname -s)" = Linux ]; then
    command -v readelf >/dev/null 2>&1 || { echo "missing command: readelf" >&2; exit 1; }
    command -v pkg-config >/dev/null 2>&1 || { echo "missing command: pkg-config" >&2; exit 1; }
fi
if [ -n "${VERSION_FILTER:-}" ]; then
    selected_versions=$(printf '%s\n' "$VERSIONS" \
        | awk -F: -v wanted="$VERSION_FILTER" '$1 == wanted { print }')
    if [ -z "$selected_versions" ]; then
        echo "VERSION_FILTER selected no pinned Lua release: $VERSION_FILTER" >&2
        exit 2
    fi
    VERSIONS=$selected_versions
fi

umask 077
mkdir -p "$SOURCE_CACHE" "$WORK_ROOT" "$EVIDENCE_DIR"
for path in "$SOURCE_CACHE" "$WORK_ROOT" "$EVIDENCE_DIR"; do
    require_owned_private_root "$path"
done
stage_source "$LUAROCKS_TARBALL" \
    "https://luarocks.org/releases/$LUAROCKS_TARBALL" "$LUAROCKS_SHA256"
printf '%s\n' "$ROCK_SOURCES" | while IFS=: read -r rock expected; do
    stage_source "$rock" "https://luarocks.org/$rock" "$expected"
done
stage_source "$LSQLITE3_ZIP" \
    'https://lua.sqlite.org/home/zip/lsqlite3_v096.zip?uuid=v0.9.6' \
    "$LSQLITE3_SHA256"
stage_source "$SQLITE_ZIP" \
    "https://www.sqlite.org/2026/$SQLITE_ZIP" "$SQLITE_SHA256"
printf '%s\n' "$VERSIONS" | while IFS=: read -r version expected; do
    stage_source "lua-$version.tar.gz" "https://www.lua.org/ftp/lua-$version.tar.gz" "$expected"
done

build_lua() {
    version=$1
    expected=$2
    prefix=$WORK_ROOT/lua-$version
    lua=$prefix/bin/lua
    luac=$prefix/bin/luac
    abi=${version%.*}
    marker=$prefix/.luainstaller-matrix-cache
    host_id=$(uname -s)-$(uname -m)
    compiler_path=$(command -v cc)
    compiler_hash=$(sha256_file "$compiler_path")
    build_id=$CACHE_SCHEMA'|component=lua|version='$version'|source='$expected'|host='$host_id'|cc='$compiler_hash'|recipe=official-posix-v3-pkgconfig'
    complete=0
    if cache_marker_matches "$marker" "$build_id" \
        && owned_regular_file "$lua" \
        && [ -x "$lua" ] \
        && owned_regular_file "$luac" \
        && [ -x "$luac" ] \
        && exact_lua_release "$lua" "$version" \
        && exact_lua_release "$luac" "$version" \
        && [ "$("$lua" -e 'io.write(_VERSION)')" = "Lua $abi" ] \
        && owned_regular_file "$prefix/include/lua.h" \
        && owned_regular_file "$prefix/include/luaconf.h" \
        && owned_regular_file "$prefix/include/lualib.h" \
        && owned_regular_file "$prefix/include/lauxlib.h" \
        && owned_regular_file "$prefix/lib/liblua.a" \
        && owned_regular_file "$prefix/lib/pkgconfig/lua.pc" \
        && [ "$(lua_pc_version "$prefix/lib/pkgconfig/lua.pc")" = "$version" ]; then
        complete=1
    fi
    if [ "$(uname -s)" = Linux ] && {
        ! owned_regular_file "$prefix/lib/liblua.so.$abi" \
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
    mkdir -p "$prefix/lib/pkgconfig"
    lua_pc=$prefix/lib/pkgconfig/lua.pc
    {
        printf 'prefix=%s\n' "$prefix"
        # shellcheck disable=SC2016 # pkg-config, not the shell, expands these variables.
        printf '%s\n' 'exec_prefix=${prefix}'
        # shellcheck disable=SC2016 # pkg-config, not the shell, expands these variables.
        printf '%s\n' 'libdir=${exec_prefix}/lib'
        # shellcheck disable=SC2016 # pkg-config, not the shell, expands these variables.
        printf '%s\n' 'includedir=${prefix}/include'
        printf '\nName: Lua\nDescription: Official Lua %s matrix runtime\n' "$version"
        printf 'Version: %s\n' "$version"
        # shellcheck disable=SC2016 # pkg-config, not the shell, expands these variables.
        printf '%s\n' 'Libs: -L${libdir} -llua -lm'
        if [ "$(uname -s)" = Linux ]; then
            printf '%s\n' 'Libs.private: -ldl'
        fi
        # shellcheck disable=SC2016 # pkg-config, not the shell, expands these variables.
        printf '%s\n' 'Cflags: -I${includedir}'
    } >"$lua_pc"
    test "$(lua_pc_version "$lua_pc")" = "$version"
    if command -v pkg-config >/dev/null 2>&1; then
        test "$(PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
            pkg-config --modversion lua)" = "$version"
    fi
    exact_lua_release "$lua" "$version"
    exact_lua_release "$luac" "$version"
    test "$("$lua" -e 'io.write(_VERSION)')" = "Lua ${version%.*}"
    write_cache_marker "$marker" "$build_id"
    printf '%s\n' "$prefix"
}

build_luarocks() {
    version=$1
    lua_prefix=$2
    lua_source=$3
    prefix=$WORK_ROOT/luarocks-$version
    command=$prefix/bin/luarocks
    marker=$prefix/.luainstaller-matrix-cache
    host_id=$(uname -s)-$(uname -m)
    compiler_hash=$(sha256_file "$(command -v cc)")
    build_id=$CACHE_SCHEMA'|component=luarocks|version='$LUAROCKS_VERSION'|source='$LUAROCKS_SHA256'|lua='$version'|lua-source='$lua_source'|host='$host_id'|cc='$compiler_hash'|recipe=configure-v2'
    if cache_marker_matches "$marker" "$build_id" \
        && owned_regular_file "$command" \
        && [ -x "$command" ] \
        && "$command" --version 2>&1 | grep -F "$LUAROCKS_VERSION" >/dev/null; then
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
    "$command" --version 2>&1 | grep -F "$LUAROCKS_VERSION" >/dev/null
    write_cache_marker "$marker" "$build_id"
    printf '%s\n' "$prefix"
}

rock_dependencies_match() {
    deps_luarocks=$1
    deps_tree=$2
    printf '%s\n' "$ROCK_INSTALL_ORDER" \
        | while IFS=: read -r rock package version; do
            "$deps_luarocks" --tree "$deps_tree" show "$package" "$version" \
                >/dev/null 2>&1 || exit 1
        done
}

native_modules_load() {
    deps_lua=$1
    deps_lua_path=$2
    deps_lua_cpath=$3
    LUA_PATH="$deps_lua_path" LUA_CPATH="$deps_lua_cpath" "$deps_lua" -e '
local cjson = require("cjson")
assert(cjson.decode(cjson.encode({ value = 17 })).value == 17)
assert(type(require("lfs").currentdir()) == "string")
assert(type(require("socket.core")) == "table")
assert(type(require("mimetypes")) == "table")
assert(type(require("zlib")) == "table")
assert(type(require("pegasus")) == "table")
local sqlite = require("lsqlite3")
local database = assert(sqlite.open_memory())
assert(database:exec("CREATE TABLE probe(value INTEGER); INSERT INTO probe VALUES(17);") == sqlite.OK)
assert(database:close())
' >/dev/null
}

build_native_dependencies() {
    deps_version=$1
    deps_source_sha256=$2
    deps_lua_prefix=$3
    deps_luarocks_prefix=$4
    deps_abi=${deps_version%.*}
    deps_lua=$deps_lua_prefix/bin/lua
    deps_luarocks=$deps_luarocks_prefix/bin/luarocks
    deps_tree=$WORK_ROOT/native-deps-$deps_version
    deps_build_dir=$WORK_ROOT/native-deps-build-$deps_version
    deps_marker=$deps_tree/.luainstaller-matrix-cache
    deps_host_id=$(uname -s)-$(uname -m)
    deps_compiler_hash=$(sha256_file "$(command -v cc)")
    deps_rock_sources_hash=$(printf '%s\n' "$ROCK_SOURCES" | sha256_stream)
    deps_install_order_hash=$(printf '%s\n' "$ROCK_INSTALL_ORDER" | sha256_stream)
    deps_build_id=$CACHE_SCHEMA'|component=native-deps|lua='$deps_version'|lua-source='$deps_source_sha256'|rocks='$deps_rock_sources_hash'|order='$deps_install_order_hash'|lsqlite='$LSQLITE3_SHA256'|sqlite='$SQLITE_SHA256'|host='$deps_host_id'|cc='$deps_compiler_hash'|recipe=pinned-src-rocks-lsqlite-v3-exact-sqlite-paths'
    deps_lua_path="$deps_tree/share/lua/$deps_abi/?.lua;$deps_tree/share/lua/$deps_abi/?/init.lua"
    deps_lua_cpath="$deps_tree/lib/lua/$deps_abi/?.so;$deps_tree/lib/lua/$deps_abi/?/init.so"

    require_no_symlink_ancestors "$deps_tree"
    require_no_symlink_ancestors "$deps_build_dir"
    printf '%s\n' \
        "native dependency cache identity: $deps_build_id" \
        "lsqlite3 binding source: archive=$LSQLITE3_ZIP sha256=$LSQLITE3_SHA256 member=$LSQLITE3_SOURCE_MEMBER" \
        "SQLite amalgamation source: archive=$SQLITE_ZIP sha256=$SQLITE_SHA256 member=$SQLITE_SOURCE_MEMBER" >&2
    if cache_marker_matches "$deps_marker" "$deps_build_id" \
        && rock_dependencies_match "$deps_luarocks" "$deps_tree" \
        && native_modules_load "$deps_lua" "$deps_lua_path" "$deps_lua_cpath"; then
        printf '%s\n' 'native dependency cache result: hit' >&2
        printf '%s\n' "$deps_tree"
        return
    fi
    printf '%s\n' 'native dependency cache result: rebuild' >&2

    rm -rf "$deps_tree" "$deps_build_dir"
    mkdir -p "$deps_tree" "$deps_build_dir"
    printf '%s\n' "$ROCK_INSTALL_ORDER" \
        | while IFS=: read -r rock package version; do
            "$deps_luarocks" --tree "$deps_tree" install --deps-mode=none \
                "$SOURCE_CACHE/$rock" >&2
            "$deps_luarocks" --tree "$deps_tree" show "$package" "$version" \
                >/dev/null 2>&1
        done

    unzip -q "$SOURCE_CACHE/$LSQLITE3_ZIP" -d "$deps_build_dir/lsqlite3-src"
    unzip -q "$SOURCE_CACHE/$SQLITE_ZIP" -d "$deps_build_dir/sqlite-src"
    deps_lsqlite_file=$deps_build_dir/lsqlite3-src/$LSQLITE3_SOURCE_MEMBER
    deps_sqlite_file=$deps_build_dir/sqlite-src/$SQLITE_SOURCE_MEMBER
    deps_lsqlite_dir=$(dirname "$deps_lsqlite_file")
    deps_sqlite_dir=$(dirname "$deps_sqlite_file")
    require_no_symlink_ancestors "$deps_lsqlite_dir"
    require_no_symlink_ancestors "$deps_sqlite_dir"
    if [ ! -f "$deps_lsqlite_file" ] || [ -L "$deps_lsqlite_file" ] \
        || [ ! -f "$deps_sqlite_file" ] || [ -L "$deps_sqlite_file" ]; then
        echo "pinned SQLite sources are missing or unsafe" >&2
        return 1
    fi
    printf '%s\n' \
        "lsqlite3 binding extraction path: $deps_lsqlite_file" \
        "SQLite amalgamation extraction path: $deps_sqlite_file" >&2
    deps_module_dir=$deps_tree/lib/lua/$deps_abi
    mkdir -p "$deps_module_dir"
    case "$(uname -s)" in
        Linux)
            cc -std=c11 -O2 -shared -fPIC \
                -I"$deps_lua_prefix/include" -I"$deps_sqlite_dir" \
                -DLSQLITE_VERSION=\"0.9.6\" \
                "$deps_lsqlite_file" "$deps_sqlite_file" \
                -o "$deps_module_dir/lsqlite3.so" -ldl -lm -pthread >&2
            ;;
        Darwin)
            cc -std=c11 -O2 -bundle -undefined dynamic_lookup \
                -I"$deps_lua_prefix/include" -I"$deps_sqlite_dir" \
                -DLSQLITE_VERSION=\"0.9.6\" \
                "$deps_lsqlite_file" "$deps_sqlite_file" \
                -o "$deps_module_dir/lsqlite3.so" >&2
            ;;
        *)
            echo "unsupported POSIX native-dependency host: $(uname -s)" >&2
            return 1
            ;;
    esac
    rock_dependencies_match "$deps_luarocks" "$deps_tree"
    native_modules_load "$deps_lua" "$deps_lua_path" "$deps_lua_cpath"
    write_cache_marker "$deps_marker" "$deps_build_id"
    rm -rf "$deps_build_dir"
    printf '%s\n' "$deps_tree"
}

run_production_edges() {
    edge_lua=$1
    if [ "$(uname -s)" != Linux ]; then
        "$edge_lua" test/production_edges.lua
        return
    fi

    case "$LUAI_MATRIX_EDGE_COVERAGE_MODE" in
        full)
            printf '%s\n' 'edge coverage gate: full; all strict prerequisites required'
            LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 \
                "$edge_lua" test/production_edges.lua
            ;;
        available)
            missing=
            for command in cc clang luajit pkg-config sha256sum \
                x86_64-w64-mingw32-gcc; do
                if ! command -v "$command" >/dev/null 2>&1; then
                    missing="$missing $command"
                fi
            done
            if [ ! -e /dev/full ]; then
                missing="$missing /dev/full"
            fi
            if [ "$(id -u)" = 0 ]; then
                missing="$missing non-root-user"
            fi
            if [ -z "$missing" ]; then
                printf '%s\n' \
                    'edge coverage gate: available host satisfies all strict prerequisites'
                LUAI_REQUIRE_FULL_EDGE_COVERAGE=1 \
                    "$edge_lua" test/production_edges.lua
            else
                printf 'edge coverage gate: available; strict edge prerequisites unavailable:%s\n' \
                    "$missing"
                "$edge_lua" test/production_edges.lua
            fi
            ;;
    esac
}

run_version() {
    version=$1
    source_sha256=$2
    lua_prefix=$(build_lua "$version" "$source_sha256")
    luarocks_prefix=$(build_luarocks "$version" "$lua_prefix" "$source_sha256")
    native_deps=$(build_native_dependencies \
        "$version" "$source_sha256" "$lua_prefix" "$luarocks_prefix")
    lua=$lua_prefix/bin/lua
    luac=$lua_prefix/bin/luac
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
    export LUAI_TEST_LUAC="$lua_prefix/bin/luac"
    export LUAI_LUA_PREFIX="$lua_prefix"
    export LUAI_LUA_RELEASE="$version"
    export LUAI_LUA_SOURCE_SHA256="$source_sha256"
    export PKG_CONFIG_PATH="$lua_prefix/lib/pkgconfig"
    DEPS_LUA_PATH="$native_deps/share/lua/${version%.*}/?.lua;$native_deps/share/lua/${version%.*}/?/init.lua"
    DEPS_LUA_CPATH="$native_deps/lib/lua/${version%.*}/?.so;$native_deps/lib/lua/${version%.*}/?/init.so"
    export DEPS_LUA_PATH DEPS_LUA_CPATH
    export LUA_PATH="$DEPS_LUA_PATH"
    export LUA_CPATH="$DEPS_LUA_CPATH"
    cd "$PROJECT_ROOT"
    find src test tools -type f -name '*.lua' -print | while IFS= read -r file; do
        "$luac" -p "$file"
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
    "$lua" test/distribution_licenses.lua
    "$lua" test/reproducible_artifacts.lua
    run_production_edges "$lua"
    "$lua" test/smoke_all.lua
    printf 'PASS host=%s lua=%s abi=%s\n' "$HOST_LABEL" "$version" "$expected"
}

printf '%s\n' "$VERSIONS" | while IFS=: read -r version expected; do
    log=$EVIDENCE_DIR/$HOST_LABEL-lua-$version.log
    set +e
    (set -e; run_version "$version" "$expected") >"$log" 2>&1
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        tail -n 1 "$log"
    else
        cat "$log" >&2
        exit "$status"
    fi
done
