#!/bin/sh
set -eu

prefix=${PREFIX:-"$HOME/.local"}
lua_bin=${LUA:-lua}

usage() {
    cat <<'USAGE'
Usage:
  sh tools/install-source.sh [--prefix DIR] [--lua LUA]

Installs luainstaller from the source tree without LuaRocks.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            if [ "$#" -lt 2 ]; then
                echo "install-source.sh: --prefix requires a directory" >&2
                exit 2
            fi
            prefix=$2
            shift 2
            ;;
        --lua)
            if [ "$#" -lt 2 ]; then
                echo "install-source.sh: --lua requires a Lua command" >&2
                exit 2
            fi
            lua_bin=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "install-source.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$prefix" ]; then
    echo "install-source.sh: --prefix must not be empty" >&2
    exit 2
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)

lua_path=$(command -v "$lua_bin" || true)
if [ -z "$lua_path" ]; then
    echo "install-source.sh: Lua command not found: $lua_bin" >&2
    exit 1
fi

if ! lua_abi=$("$lua_path" -e 'io.write(_VERSION)' 2>/dev/null); then
    echo "install-source.sh: cannot query Lua interpreter: $lua_path" >&2
    exit 1
fi
if [ "$lua_abi" != "Lua 5.4" ]; then
    echo "install-source.sh: Lua 5.4 is required; $lua_path reported ${lua_abi:-unknown}" >&2
    exit 1
fi
lua_version=5.4
lua_share="$prefix/share/lua/$lua_version"
module_dir="$lua_share/luainstaller"
bin_dir="$prefix/bin"
man_dir="$prefix/share/man/man1"

mkdir -p "$module_dir" "$bin_dir" "$man_dir"
cp "$project_root/src/init.lua" "$lua_share/luainstaller.lua"
for module in analyzer bundler cgen cli compat discovery fs hash launcher logger manifest onefile path platform process result runtime; do
    cp "$project_root/src/$module.lua" "$module_dir/$module.lua"
done
cp "$project_root/luainstaller.1" "$man_dir/luai.1"
cp "$project_root/luainstaller.1" "$man_dir/luainstaller.1"

write_wrapper() {
    name=$1
    cat > "$bin_dir/$name" <<SH
#!/bin/sh
set -eu

lua_bin=\${LUAI_LUA:-"$lua_path"}
if ! lua_abi=\$("\$lua_bin" -e 'io.write(_VERSION)' 2>/dev/null); then
    echo "$name: cannot query Lua interpreter: \$lua_bin" >&2
    exit 1
fi
if [ "\$lua_abi" != "Lua 5.4" ]; then
    echo "$name: Lua 5.4 is required; \$lua_bin reported \${lua_abi:-unknown}" >&2
    exit 1
fi
prefix_root=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)
to_lua_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "\$1"
    else
        printf '%s\n' "\$1"
    fi
}
lua_share_fs="\$prefix_root/share/lua/$lua_version"
lua_share=\$(to_lua_path "\$lua_share_fs")
cli_path=\$(to_lua_path "\$lua_share_fs/luainstaller/cli.lua")
export LUA_PATH="\$lua_share/?.lua;\$lua_share/?/init.lua;\${LUA_PATH:-;;}"
export LUAINSTALLER_CLI_NAME="$name"
exec "\$lua_bin" "\$cli_path" "\$@"
SH
    chmod +x "$bin_dir/$name"
}

write_wrapper luai
write_wrapper luainstaller

printf 'installed luai and luainstaller to %s\n' "$bin_dir"
printf 'installed man pages to %s\n' "$man_dir"
