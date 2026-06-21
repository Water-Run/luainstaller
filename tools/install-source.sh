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

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

lua_path=$(command -v "$lua_bin" || true)
if [ -z "$lua_path" ]; then
    echo "install-source.sh: Lua command not found: $lua_bin" >&2
    exit 1
fi

lua_version=$("$lua_path" -e 'local v = _VERSION:match("(%d+%.%d+)"); assert(v); print(v)')
lua_share="$prefix/share/lua/$lua_version"
module_dir="$lua_share/luainstaller"
bin_dir="$prefix/bin"

mkdir -p "$module_dir" "$bin_dir"
cp "$project_root/src/init.lua" "$lua_share/luainstaller.lua"
for module in analyzer bundler cgen cli launcher logger manifest runtime; do
    cp "$project_root/src/$module.lua" "$module_dir/$module.lua"
done

cat > "$bin_dir/luai" <<SH
#!/bin/sh
set -eu

lua_bin=\${LUAI_LUA:-"$lua_path"}
prefix_root=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)
lua_share="\$prefix_root/share/lua/$lua_version"
export LUA_PATH="\$lua_share/?.lua;\$lua_share/?/init.lua;\${LUA_PATH:-;;}"
exec "\$lua_bin" "\$lua_share/luainstaller/cli.lua" "\$@"
SH
chmod +x "$bin_dir/luai"

printf 'installed luai to %s\n' "$bin_dir/luai"
