#!/usr/bin/env bash
# shared paths and helper lookup for the secret commands. source this file,
# never run it directly.

# ---------------------------------------------------------------------------
# Platform layer
#
# The same handful of functions exist in lib/agent-secrets-helper. That copy is
# deliberate: the helper runs as root through sudo and must never source a file
# this account can write, so there is no shared portable.sh to point both at.
# Keep the two in step when you change either.

agent_secrets_os="$(uname -s)"
case "$agent_secrets_os" in
    Linux|Darwin) ;;
    CYGWIN*|MINGW*|MSYS*)
        echo "error: windows is not supported natively. run agent-secrets inside wsl2." >&2
        exit 1 ;;
    *)
        echo "error: unsupported platform: $agent_secrets_os (linux and macos only)" >&2
        exit 1 ;;
esac

stat_owner() {
    if [[ "$agent_secrets_os" == Darwin ]]; then stat -f '%Su:%Sg %Lp' -- "$1"
    else stat -c '%U:%G %a' -- "$1"; fi
}

sha256_of_stdin() {
    if [[ "$agent_secrets_os" == Darwin ]]; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1
}

# Overwriting before unlinking is close to meaningless on a copy-on-write or
# flash-translated filesystem, which is most of them now. It still costs
# nothing, and it keeps the plaintext out of a file that a later `undelete`
# would hand back whole.
secure_rm() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -u -- "$f" 2>/dev/null && return 0
    fi
    if [[ "$agent_secrets_os" == Darwin ]]; then
        rm -P -f -- "$f" 2>/dev/null && return 0
    fi
    rm -f -- "$f"
}

# every one of these is read by the commands that source this file, which a
# static linter cannot see from here.
# shellcheck disable=SC2034
secrets_dir="${AGENT_SECRETS_DIR:-$HOME/.secrets}"
# shellcheck disable=SC2034
secrets_key_dir="$secrets_dir/key"
secrets_key="$secrets_key_dir/.key"
secrets_scopes_dir="$secrets_dir/scopes"
# shellcheck disable=SC2034
secrets_index_dir="$secrets_dir/index"

# the local helper makes the first setup usable without sudo. after the root
# install, the installed helper owns the key and always wins this lookup.
readonly agent_secrets_helper_installed="${AGENT_SECRETS_HELPER_INSTALLED:-/usr/local/libexec/agent-secrets-helper}"
readonly agent_secrets_helper_local="${AGENT_SECRETS_HELPER_LOCAL:-$HOME/.local/libexec/agent-secrets-helper}"

secret_helper() {
    if [[ -x "$agent_secrets_helper_installed" ]]; then
        sudo -n "$agent_secrets_helper_installed" "$@"
    elif [[ -x "$agent_secrets_helper_local" ]]; then
        "$agent_secrets_helper_local" "$@"
    else
        echo "error: no agent-secrets helper found. run install.sh first" >&2
        return 78
    fi
}

secret_helper_hardened() { [[ -x "$agent_secrets_helper_installed" ]]; }

list_scopes() {
    local file
    shopt -s nullglob
    for file in "$secrets_scopes_dir"/*.env.gpg; do
        file="${file##*/}"
        printf '%s\n' "${file%.env.gpg}"
    done
    shopt -u nullglob
}

scopes_line() {
    local existing
    existing="$(list_scopes | paste -sd' ' -)"
    printf '%s' "${existing:-<none>}"
}

validate_scope() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || {
        echo "error: scope names use lowercase letters, digits, '-' and '_' (got '$1')" >&2
        exit 1
    }
}

ensure_key() {
    [[ -e "$secrets_key" ]] && return 0
    echo "error: no key at $secrets_key" >&2
    if secret_helper_hardened; then
        echo "restore it from your password manager as root:root with mode 0600." >&2
    else
        echo "restore it from your password manager. without it every scope is unreadable." >&2
    fi
    return 1
}
