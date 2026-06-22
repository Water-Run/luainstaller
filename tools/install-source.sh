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
man_dir="$prefix/share/man/man1"

mkdir -p "$module_dir" "$bin_dir" "$man_dir"
cp "$project_root/src/init.lua" "$lua_share/luainstaller.lua"
for module in analyzer bundler cgen cli compat launcher logger manifest onefile platform require_engine runtime; do
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
prefix_root=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)
lua_share="\$prefix_root/share/lua/$lua_version"
export LUA_PATH="\$lua_share/?.lua;\$lua_share/?/init.lua;\${LUA_PATH:-;;}"
exec "\$lua_bin" "\$lua_share/luainstaller/cli.lua" "\$@"
SH
    chmod +x "$bin_dir/$name"
}

write_wrapper luai
write_wrapper luainstaller

printf 'installed luai and luainstaller to %s\n' "$bin_dir"
printf 'installed man pages to %s\n' "$man_dir"
