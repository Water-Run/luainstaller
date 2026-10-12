#!/bin/sh
set -eu

# Dedicated CI roots may be rebuilt; unrelated existing directories may not.
luai_ci_validate_root() {
    luai_ci_root=$1
    case "$luai_ci_root" in
        /*) ;;
        *) echo "CI root must be absolute: $luai_ci_root" >&2; return 1 ;;
    esac
    case "$luai_ci_root" in
        /|/tmp|/var|/var/tmp|/usr|/usr/local|/etc|/home|/root|/opt|/run|*/|*'//'*|*'/../'*|*'/..'|*'/./'*|*'/.')
            echo "unsafe CI root: $luai_ci_root" >&2; return 1 ;;
    esac
    if [ "$luai_ci_root" = "${HOME%/}" ]; then
        echo "CI root cannot be the home directory" >&2
        return 1
    fi
    luai_ci_ancestor=$luai_ci_root
    while [ -n "$luai_ci_ancestor" ] && [ "$luai_ci_ancestor" != / ]; do
        if [ -L "$luai_ci_ancestor" ] \
            || { [ -e "$luai_ci_ancestor" ] && [ ! -d "$luai_ci_ancestor" ]; }; then
            echo "unsafe CI root ancestor: $luai_ci_ancestor" >&2
            return 1
        fi
        luai_ci_ancestor=${luai_ci_ancestor%/*}
    done
}

luai_ci_claim_root() {
    luai_ci_validate_root "$1" || return 1
    luai_ci_marker=$luai_ci_root/.luainstaller-ci-owner
    luai_ci_identity="luainstaller-ci-directory-v1:$2:$(id -u)"
    if [ -d "$luai_ci_root" ]; then
        # Numeric ls output is available on the native CI hosts.
        luai_ci_owner=$(LC_ALL=C ls -dn "$luai_ci_root" | awk '{print $3}')
        if [ "$luai_ci_owner" != "$(id -u)" ]; then
            echo "CI root is not owned by this user: $luai_ci_root" >&2
            return 1
        fi
        if [ -L "$luai_ci_marker" ]; then
            echo "CI root marker is a symlink: $luai_ci_marker" >&2
            return 1
        fi
        if [ -e "$luai_ci_marker" ]; then
            if [ ! -f "$luai_ci_marker" ] \
                || [ "$(cat "$luai_ci_marker")" != "$luai_ci_identity" ]; then
                echo "CI root has a different ownership marker: $luai_ci_root" >&2
                return 1
            fi
        else
            luai_ci_entries=$(LC_ALL=C ls -A "$luai_ci_root") || return 1
            if [ -n "$luai_ci_entries" ]; then
                echo "CI root contains unowned files; choose a new dedicated directory: $luai_ci_root" >&2
                return 1
            fi
        fi
    else
        (umask 077; mkdir -p "$luai_ci_root") || return 1
    fi
    chmod 700 "$luai_ci_root" || return 1
    if [ ! -f "$luai_ci_marker" ]; then
        (umask 077; printf '%s\n' "$luai_ci_identity" >"$luai_ci_marker") || return 1
    fi
}

luai_ci_disjoint_roots() {
    case "$1/" in
        "$2/"*) echo "CI roots must be separate: $1 and $2" >&2; return 1 ;;
    esac
    case "$2/" in
        "$1/"*) echo "CI roots must be separate: $1 and $2" >&2; return 1 ;;
    esac
}
