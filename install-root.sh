#!/usr/bin/env bash
# install the privileged helper and the narrow sudo rule that can call it.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run this with sudo" >&2; exit 1; }
real_user="${SUDO_USER:-}"
[[ -n "$real_user" && "$real_user" != root ]] || {
    echo "run this through sudo from the account that owns the store" >&2
    exit 1
}
real_home="$(getent passwd "$real_user" | cut -d: -f6)"
[[ -n "$real_home" ]] || { echo "error: cannot find a home directory for $real_user" >&2; exit 1; }

source_file="$real_home/.local/libexec/agent-secrets-helper"
destination=/usr/local/libexec/agent-secrets-helper
sudoers_file=/etc/sudoers.d/agent-secrets-helper
key_file="$real_home/.secrets/key/.key"
uid="$(id -u "$real_user")"

[[ -r "$source_file" ]] || {
    echo "error: no helper source at $source_file. run install.sh as $real_user first." >&2
    exit 1
}
[[ -r "$key_file" ]] || {
    echo "error: no key at $key_file. run secret-init as $real_user first." >&2
    exit 1
}

install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$source_file" "$destination"
chown root:root "$key_file"
chmod 600 "$key_file"

printf '%s ALL=(root) NOPASSWD: %s\n' "$real_user" "$destination" > "$sudoers_file"
chmod 440 "$sudoers_file"
if ! visudo -cf "$sudoers_file" >/dev/null; then
    rm -f "$sudoers_file"
    echo "error: sudoers syntax check failed. removed $sudoers_file" >&2
    exit 1
fi

install -d -o root -g root -m 0700 /run/agent-secrets-gate
install -d -o root -g root -m 0700 "/run/agent-secrets-gate/$uid"
echo "installed the root-owned helper and locked the key"
echo "run secret-helper-status to inspect the result"
