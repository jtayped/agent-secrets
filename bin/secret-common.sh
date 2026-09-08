#!/usr/bin/env bash
# shared paths and helper lookup for the secret commands. source this file,
# never run it directly.

secrets_dir="${AGENT_SECRETS_DIR:-$HOME/.secrets}"
secrets_key_dir="$secrets_dir/key"
secrets_key="$secrets_key_dir/.key"
secrets_scopes_dir="$secrets_dir/scopes"
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
