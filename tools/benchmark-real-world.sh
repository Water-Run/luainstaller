#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

LUAI_BIN=${LUAI_BIN:-}
LUA_BIN=${LUA_BIN:-lua}
LUAROCKS_BIN=${LUAROCKS_BIN:-luarocks}
WORK_ROOT=${WORK_ROOT:-/tmp/luainstaller-benchmark}
FAKE_SCALES=${FAKE_SCALES:-"100 1000 10000"}
KEEP_WORKSPACE=${KEEP_WORKSPACE:-0}
SKIP_EXTERNAL=${SKIP_EXTERNAL:-0}
SKIP_NATIVE=${SKIP_NATIVE:-0}
NEOVIM_MAX_DEPS=${NEOVIM_MAX_DEPS:-12000}
NEOVIM_WRAP_LIMIT=${NEOVIM_WRAP_LIMIT:-200}
DEFAULT_MAX_DEPS=${DEFAULT_MAX_DEPS:-5000}
SCRIPT_LUA_ABI=$("$LUA_BIN" -e 'io.write(_VERSION:match("%d+%.%d+") )')
ROCK_ROOT="$WORK_ROOT/rocks"
RESULTS_DIR="$WORK_ROOT/results"
LOG_DIR="$RESULTS_DIR/logs"
SUMMARY="$RESULTS_DIR/summary.txt"
NEOVIM_TIMEOUT=${NEOVIM_TIMEOUT:-30}
COMMAND_TIMEOUT=${LUAI_CMD_TIMEOUT:-600}
failures=()
incomplete=()

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --work-root PATH    workspace root (default: $WORK_ROOT)
  --keep-workspace    keep workspace after completion
  --skip-external     skip external GitHub clones
  --skip-native       skip lua-cjson and LuaSocket native install/case
  --fake-scales N1 N2... comma/space list (default: $FAKE_SCALES)
  --max-deps N        default max-deps for static cases (default: $DEFAULT_MAX_DEPS)
  --neovim-max-deps N max-deps for neovim wrapper case (default: $NEOVIM_MAX_DEPS)
  --neovim-timeout N  timeout in seconds for neovim case commands (default: $NEOVIM_TIMEOUT)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --work-root)
            WORK_ROOT=${2:?missing value}
            shift 2
            ;;
        --keep-workspace)
            KEEP_WORKSPACE=1
            shift
            ;;
        --skip-external)
            SKIP_EXTERNAL=1
            shift
            ;;
        --skip-native)
            SKIP_NATIVE=1
            shift
            ;;
        --fake-scales)
            FAKE_SCALES=${2:?missing value}
            shift 2
            ;;
        --max-deps)
            DEFAULT_MAX_DEPS=${2:?missing value}
            shift 2
            ;;
        --neovim-max-deps)
            NEOVIM_MAX_DEPS=${2:?missing value}
            shift 2
            ;;
        --neovim-timeout)
            NEOVIM_TIMEOUT=${2:?missing value}
            shift 2
            ;;
        *)
            echo "unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

positive_integer() {
    [[ "$2" =~ ^[0-9]+$ ]] && [ "${#2}" -le 8 ] && [ "$2" -gt 0 ] && [ "$2" -le "$3" ] || {
        echo "$1 must be an integer between 1 and $3" >&2
        exit 2
    }
}

compact_scales=${FAKE_SCALES//[[:space:]]/}
case "$compact_scales" in
    ''|,*|*,|*,,*) echo 'invalid --fake-scales list' >&2; exit 2 ;;
esac
read -r -a scales <<< "${FAKE_SCALES//[[:space:],]/ }"
for n in "${scales[@]}"; do positive_integer --fake-scales "$n" 1000000; done
positive_integer --max-deps "$DEFAULT_MAX_DEPS" 1000000
positive_integer --neovim-max-deps "$NEOVIM_MAX_DEPS" 1000000
positive_integer --neovim-timeout "$NEOVIM_TIMEOUT" 86400
positive_integer LUAI_CMD_TIMEOUT "$COMMAND_TIMEOUT" 86400
case "$WORK_ROOT" in
    /tmp/luainstaller-*) ;;
    *) echo "unsafe work root: $WORK_ROOT" >&2; exit 2 ;;
esac
WORK_ROOT=$(mktemp -d "${WORK_ROOT}-XXXXXX")
RESULTS_DIR=$(mktemp -d /tmp/luainstaller-benchmark-results-XXXXXX)
LOG_DIR="$RESULTS_DIR/logs"
SUMMARY="$RESULTS_DIR/summary.txt"
ROCK_ROOT="$WORK_ROOT/rocks"

mkdir -p "$LOG_DIR"

cleanup() {
    local status=$?
    printf "driver exit=%s\n" "$status" >> "$SUMMARY"
    echo "summary file: $SUMMARY"
    if [ "$KEEP_WORKSPACE" -eq 1 ]; then
        echo "workspace kept: $WORK_ROOT"
    else
        rm -rf "$WORK_ROOT"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

if [ -z "$LUAI_BIN" ]; then
    LUAI_BIN="$WORK_ROOT/luai-source"
    printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$LUA_BIN" "$PROJECT_ROOT/bin/luai.lua" > "$LUAI_BIN"
    chmod +x "$LUAI_BIN"
fi

require_cmds() {
    for c in bash git gcc make awk tar; do
        if ! command -v "$c" >/dev/null 2>&1; then
            echo "missing command: $c" >&2
            exit 1
        fi
    done
}

safe_path() {
    case "$1" in
        /tmp/luainstaller-*) return 0 ;;
        *) echo "unsafe work root: $1" >&2; exit 2 ;;
    esac
}

safe_path "$WORK_ROOT"
require_cmds

log() {
    printf '%s %s\n' "[$(date +'%Y-%m-%d %H:%M:%S')]" "$*" | tee -a "$SUMMARY"
}

run_cmd() {
    local label=$1
    local logfile=$2
    local expect_fail=$3
    local cmd_timeout=${CASE_TIMEOUT:-$COMMAND_TIMEOUT}
    local start
    local code
    shift 3
    start=$SECONDS
    set +e
    "$LUA_BIN" "$PROJECT_ROOT/tools/benchmark-command.lua" "$cmd_timeout" "$@" >"$logfile" 2>&1
    code=$?
    set -e
    local elapsed_ms=$(( (SECONDS - start) * 1000 ))
    if [ "$expect_fail" -eq 1 ]; then
        if [ "$code" -eq 1 ] && grep -q '^error: DynamicRequireError:' "$logfile"; then
            log "[EXPECT_FAIL] $label in ${elapsed_ms}ms (DynamicRequireError)"
        else
            log "[FAIL] $label expected DynamicRequireError (exit=$code)"
            failures+=("$label")
        fi
    elif [ "$expect_fail" -eq 2 ] && [ "$code" -eq 1 ] && grep -q '^error: DiscoveryError:' "$logfile"; then
        log "[EXPLORATORY] $label could not run outside its application host"
        incomplete+=("$label")
    elif [ "$code" -eq 0 ]; then
        log "[OK] $label in ${elapsed_ms}ms"
    else
        log "[FAIL] $label in ${elapsed_ms}ms (exit=$code)"
        failures+=("$label")
    fi
    return "$code"
}

run_case() {
    local name=$1
    local entry=$2
    local out=$3
    local max_deps=$4
    local discovery=$5
    local lua_path=$6
    local lua_cpath=$7
    local expect_fail=${8:-0}
    local runtime_exec=${9:-0}
    local CASE_TIMEOUT=${10:-$COMMAND_TIMEOUT}

    mkdir -p "$out"
    log "### $name"
    log "entry=$entry"

    local env_prefix=()
    [ -n "$lua_path" ] && env_prefix+=(LUA_PATH="${lua_path};;")
    [ -n "$lua_cpath" ] && env_prefix+=(LUA_CPATH="${lua_cpath};;")

    run_cmd "$name analyze" "$LOG_DIR/$name-analyze.log" "$expect_fail" \
        env "${env_prefix[@]}" "$LUAI_BIN" -a "$entry" -d "$discovery" --max-deps "$max_deps" || true

    run_cmd "$name bundle(dir)" "$LOG_DIR/$name-bundle-dir.log" "$expect_fail" \
        env "${env_prefix[@]}" "$LUAI_BIN" -b --dir "$entry" -d "$discovery" -o "$out/dir" --max-deps "$max_deps" || true
    run_cmd "$name bundle(file)" "$LOG_DIR/$name-bundle-onefile.log" "$expect_fail" \
        env "${env_prefix[@]}" "$LUAI_BIN" -b --file "$entry" -d "$discovery" -o "$out/onefile" --max-deps "$max_deps" || true

    if [ "$runtime_exec" -eq 1 ]; then
        local exe_dir_name launcher_dir empty_path
        exe_dir_name=$(basename "$out/dir")
        if [ -x "$out/dir/$exe_dir_name" ]; then
            launcher_dir="$out/dir/$exe_dir_name"
        elif [ -x "$out/dir/$(basename "$entry")" ]; then
            launcher_dir="$out/dir/$(basename "$entry")"
        elif [ -x "$out/dir/$(basename "$entry" .lua)" ]; then
            launcher_dir="$out/dir/$(basename "$entry" .lua)"
        else
            launcher_dir=
        fi

        empty_path=$(mktemp -d /tmp/luainstaller-empty-path-XXXXXX)
        local CASE_TIMEOUT=6
        if [ -n "$launcher_dir" ]; then
            run_cmd "$name dir-exec" "$LOG_DIR/$name-dir-exec.log" 0 \
                env -i PATH="$empty_path" "$launcher_dir" || true
        else
            log "[FAIL] $name dir executable not found"
            failures+=("$name dir executable")
        fi
        if [ -x "$out/onefile" ]; then
            run_cmd "$name onefile-exec" "$LOG_DIR/$name-onefile-exec.log" 0 \
                env -i PATH="$empty_path" "$out/onefile" || true
        else
            log "[FAIL] $name onefile binary missing"
            failures+=("$name onefile binary")
        fi
        rm -rf "$empty_path"
    else
        log "$name runtime probes skipped"
    fi
}

git_clone_or_fail() {
    local url=$1
    local dir=$2
    local clone_log
    clone_log="$LOG_DIR/git-clone-${dir##*/}.log"
    rm -rf "$dir"
    local CASE_TIMEOUT=120
    if ! "$LUA_BIN" "$PROJECT_ROOT/tools/benchmark-command.lua" "$CASE_TIMEOUT" \
        git clone --depth 1 --filter=blob:none "$url" "$dir" >"$clone_log" 2>&1; then
        if ! "$LUA_BIN" "$PROJECT_ROOT/tools/benchmark-command.lua" "$CASE_TIMEOUT" \
            git clone --depth 1 "$url" "$dir" >>"$clone_log" 2>&1; then
            log "[FAIL] git clone failed $url"
            failures+=("git clone $url")
            return 1
        fi
    fi
    return 0
}

make_fake_project() {
    local root=$1
    local n=$2
    mkdir -p "$root"
    local i=1
    while [ "$i" -le "$n" ]; do
        local mod
        mod=$(printf 'module_%04d' "$i")
        cat > "$root/${mod}.lua" <<EOF
local M = {}
function M.id()
    return $i
end
return M
EOF
        i=$((i + 1))
    done

    printf 'require(\"module_0001\")\n' > "$root/main.lua"
    i=2
    while [ "$i" -le "$n" ]; do
        local mod
        mod=$(printf 'module_%04d' "$i")
        printf 'require(\"%s\")\n' "$mod" >> "$root/main.lua"
        i=$((i + 1))
    done
}

make_neovim_wrapper() {
    local root=$1
    local out=$2
    local limit=${3:-0}
    local file
    local first=1
    local count=0
    rm -rf "$out"
    mkdir -p "$out"
    (cd "$root" && find . -type f -name '*.lua' -print0 | tar -cf - --null -T -) \
        | (cd "$out" && tar -xf -)
    cat > "$out/main.lua" <<'EOF'
local missing = {}
EOF
    while IFS= read -r file; do
        if [ "$limit" -gt 0 ]; then
            count=$((count + 1))
            [ "$count" -gt "$limit" ] && break
        fi
        rel=${file#"$root/"}
        mod=${rel%.lua}
        mod=${mod//\//.}
        mod=${mod%.init}
        if [ -n "$mod" ]; then
            if [ "$first" -eq 1 ]; then
                first=0
            fi
            printf 'if not pcall(require, "%s") then\n    table.insert(missing, "%s")\nend\n' "$mod" "$mod" >> "$out/main.lua"
        fi
    done < <(find "$root" -type f -name '*.lua' | sort)
    cat >> "$out/main.lua" <<'EOF'
if #missing > 0 then
    -- keep behavior deterministic for runtime packaging
    -- and avoid side-effects in test traces.
    print("missing_modules=" .. #missing)
end
return true
EOF
}

log "luainstaller benchmark start"
log "luai: $LUAI_BIN"
log "lua : $LUA_BIN"
log "luarocks: $LUAROCKS_BIN"
log "lua ABI: $SCRIPT_LUA_ABI"
log "workspace: $WORK_ROOT"
log "lua command: $(command -v "$LUA_BIN")"
run_cmd "luai version" "$LOG_DIR/luai-version.log" 0 "$LUAI_BIN" -v || true

# A. baseline hello world
run_case "hello_world" "$PROJECT_ROOT/test/single_file/01_hello_luainstaller.lua" \
    "$WORK_ROOT/case-hello" "$DEFAULT_MAX_DEPS" "static" "" "" 0 1

# Pure Lua multi-module stress
make_fake_project "$WORK_ROOT/pure-modules" 120
run_case "pure_lua_multi_modules" "$WORK_ROOT/pure-modules/main.lua" \
    "$WORK_ROOT/case-pure-multi" "$DEFAULT_MAX_DEPS" "static" "" "" 0 1

# Dynamic require project (runtime discovery)
mkdir -p "$WORK_ROOT/dynamic-require"
cat > "$WORK_ROOT/dynamic-require/main.lua" <<'EOF'
local modules = {"module_0001", "module_0002", "module_0003"}
for _, name in ipairs(modules) do
    local ok, mod = pcall(require, name)
    if not ok then
        _G._missing = (_G._missing or 0) + 1
    end
end
for i = 1, 3 do
    local name = ("module_%04d"):format(i)
    local ok = pcall(require, name)
    if not ok then
        _G._missing = (_G._missing or 0) + 1
    end
end
return true
EOF
cat > "$WORK_ROOT/dynamic-require/module_0001.lua" <<'EOF'
return {name = "m1"}
EOF
cat > "$WORK_ROOT/dynamic-require/module_0002.lua" <<'EOF'
return {name = "m2"}
EOF
cat > "$WORK_ROOT/dynamic-require/module_0003.lua" <<'EOF'
return {name = "m3"}
EOF
run_case "dynamic_require_static" "$WORK_ROOT/dynamic-require/main.lua" \
    "$WORK_ROOT/case-dynamic-static" "$DEFAULT_MAX_DEPS" "static" "" "" 1 0
run_case "dynamic_require_runtime" "$WORK_ROOT/dynamic-require/main.lua" \
    "$WORK_ROOT/case-dynamic-runtime" "$DEFAULT_MAX_DEPS" "runtime" "" "" 0 1

cpath=
lua_path=
cjson_ready=0
if [ "$SKIP_NATIVE" -eq 0 ]; then
    mkdir -p "$ROCK_ROOT"
    cpath="${ROCK_ROOT}/lib/lua/$SCRIPT_LUA_ABI/?.so"
    lua_path="${ROCK_ROOT}/share/lua/$SCRIPT_LUA_ABI/?.lua;${ROCK_ROOT}/share/lua/$SCRIPT_LUA_ABI/?/init.lua"

    if "$LUA_BIN" "$PROJECT_ROOT/tools/benchmark-command.lua" "$COMMAND_TIMEOUT" \
        "$LUAROCKS_BIN" --tree "$ROCK_ROOT" --lua-version "$SCRIPT_LUA_ABI" \
        install lua-cjson 2.1.0.10-1 \
        >"$LOG_DIR/luarocks-install-lua-cjson.log" 2>&1; then
        cjson_ready=1
        cat > "$WORK_ROOT/cjson-main.lua" <<'EOF'
local cjson = require("cjson")
print(cjson.encode({ok = true}))
EOF
        run_case "lua-cjson" "$WORK_ROOT/cjson-main.lua" \
            "$WORK_ROOT/case-lua-cjson" "$DEFAULT_MAX_DEPS" "static" "$lua_path" "$cpath" 0 1
    else
        log "[FAIL] lua-cjson install failed"
        failures+=("lua-cjson install")
    fi

    if "$LUA_BIN" "$PROJECT_ROOT/tools/benchmark-command.lua" "$COMMAND_TIMEOUT" \
        "$LUAROCKS_BIN" --tree "$ROCK_ROOT" --lua-version "$SCRIPT_LUA_ABI" \
        install luasocket 3.1.0-1 \
        >"$LOG_DIR/luarocks-install-luasocket.log" 2>&1; then
        cat > "$WORK_ROOT/luasocket-main.lua" <<'EOF'
local socket = require("socket")
local tp = require("socket.tp")
local ftp = require("socket.ftp")
local ltn12 = require("ltn12")
print(type(socket.gettime()))
print(type(tp.connect))
print(type(ftp))
print(type(ltn12.source))
EOF
        run_case "luasocket" "$WORK_ROOT/luasocket-main.lua" \
            "$WORK_ROOT/case-luasocket" "$DEFAULT_MAX_DEPS" "static" "$lua_path" "$cpath" 0 1
    else
        log "[FAIL] luasocket install failed"
        failures+=("luasocket install")
    fi

    if "$LUA_BIN" "$PROJECT_ROOT/tools/benchmark-command.lua" "$COMMAND_TIMEOUT" \
        "$LUAROCKS_BIN" --tree "$ROCK_ROOT" --lua-version "$SCRIPT_LUA_ABI" \
        install luafilesystem 1.9.0-1 \
        >"$LOG_DIR/luarocks-install-luafilesystem.log" 2>&1; then
        cat > "$WORK_ROOT/luafilesystem-main.lua" <<'EOF'
local lfs = require("lfs")
print(type(lfs.currentdir()))
EOF
        run_case "luafilesystem" "$WORK_ROOT/luafilesystem-main.lua" \
            "$WORK_ROOT/case-luafilesystem" "$DEFAULT_MAX_DEPS" "static" "$lua_path" "$cpath" 0 1
    else
        log "[FAIL] luafilesystem install failed"
        failures+=("luafilesystem install")
    fi
else
    log "skip-native enabled"
    incomplete+=("native cases explicitly skipped")
fi

if [ "$SKIP_EXTERNAL" -eq 0 ]; then
    # B. Luacheck parser dependency graph (real pure-Lua project)
    if git_clone_or_fail \
        "https://github.com/lunarmodules/luacheck" \
        "$WORK_ROOT/luacheck"; then
        LUACHECK_ENTRY="$WORK_ROOT/luacheck/src/luacheck/parser.lua"
        if [ -f "$LUACHECK_ENTRY" ]; then
            luacheck_path="$WORK_ROOT/luacheck/src/?.lua;$WORK_ROOT/luacheck/src/?/init.lua"
            run_case "luacheck_parser" "$LUACHECK_ENTRY" \
                "$WORK_ROOT/case-luacheck-parser" "$DEFAULT_MAX_DEPS" \
                "static" "$luacheck_path" "" 0 1
        else
            log "[FAIL] luacheck parser entry missing"
            failures+=("luacheck parser entry")
        fi
    else
        if [ "$cjson_ready" -eq 1 ]; then
            log "fallback: luacheck unavailable, testing local student_management_system"
            run_case "student_management_system" \
                "$PROJECT_ROOT/test/student_management_system/main.lua" \
                "$WORK_ROOT/case-student-management-fallback" \
                "$DEFAULT_MAX_DEPS" "static" "$lua_path" "$cpath" 0 0
        else
            log "skip: luacheck unavailable and local fallback requires lua-cjson"
        fi
    fi

    # E. neovim runtime Lua stress
    if git_clone_or_fail \
        "https://github.com/neovim/neovim" \
        "$WORK_ROOT/neovim"; then
        NVM_RUNTIME="$WORK_ROOT/neovim/runtime/lua"
        if [ -d "$NVM_RUNTIME" ]; then
            mkdir -p "$WORK_ROOT/neovim-wrapper"
            make_neovim_wrapper "$NVM_RUNTIME" "$WORK_ROOT/neovim-wrapper" "$NEOVIM_WRAP_LIMIT"
            run_case "neovim_runtime_lua" "$WORK_ROOT/neovim-wrapper/main.lua" \
                "$WORK_ROOT/case-neovim-runtime" "$NEOVIM_MAX_DEPS" "runtime" "" "" 2 0 "$NEOVIM_TIMEOUT"
        else
            log "[FAIL] neovim runtime/lua not found"
            failures+=("neovim runtime entry")
        fi
    fi
else
    log "skip-external enabled"
    incomplete+=("external cases explicitly skipped")
fi

for n in "${scales[@]}"; do
    n=$((10#$n))
    make_fake_project "$WORK_ROOT/fake-$n" "$n"
    run_case "fake_${n}" "$WORK_ROOT/fake-$n/main.lua" \
        "$WORK_ROOT/case-fake-${n}" "$((n + 100))" "static" "" "" 0 1
done

log "== SUMMARY =="
benchmark_status=0
if [ ${#failures[@]} -eq 0 ]; then
    if [ ${#incomplete[@]} -eq 0 ]; then
        log "all cases completed"
    else
        log "incomplete coverage: ${incomplete[*]}"
    fi
else
    log "failed: ${failures[*]}"
    benchmark_status=1
fi
log "summary file: $SUMMARY"
exit "$benchmark_status"
