#!/usr/bin/env bash
# install the privileged helper and the narrow sudo rule that can call it.
#
# this is the step that turns the approval dialog from a reminder into a
# control. it only makes sense if root, and only root, can replace the helper,
# the interpreter that runs it, and the gpg it calls. on linux that is the
# normal state of the system directories. on macos it often is not: homebrew
# owns /opt/homebrew, and on intel machines it owns /usr/local too, so a helper
# installed under either could be rewritten by the account it is supposed to be
# protecting against. every path is checked below rather than assumed.
set -euo pipefail

os="$(uname -s)"
case "$os" in
    Linux|Darwin) ;;
    CYGWIN*|MINGW*|MSYS*)
        echo "error: windows is not supported natively. run agent-secrets inside wsl2." >&2
        exit 1 ;;
    *) echo "error: unsupported platform: $os" >&2; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || { echo "run this with sudo" >&2; exit 1; }
real_user="${SUDO_USER:-}"
[[ -n "$real_user" && "$real_user" != root ]] || {
    echo "run this through sudo from the account that owns the store" >&2
    exit 1
}

if [[ "$os" == Darwin ]]; then
    root_group=wheel
    runtime_root=/var/run/agent-secrets-gate
    real_home="$(dscl . -read "/Users/$real_user" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: *//')"
else
    root_group=root
    runtime_root=/run/agent-secrets-gate
    real_home="$(getent passwd "$real_user" | cut -d: -f6)"
fi
[[ -n "$real_home" ]] || { echo "error: cannot find a home directory for $real_user" >&2; exit 1; }

stat_owner_uid() { if [[ "$os" == Darwin ]]; then stat -f '%u' -- "$1"; else stat -c '%u' -- "$1"; fi; }
stat_mode()      { if [[ "$os" == Darwin ]]; then stat -f '%Lp' -- "$1"; else stat -c '%a' -- "$1"; fi; }

# root owns this path and every directory above it, and nobody else can write
# any of them.
path_is_trusted() {
    local p="$1" owner mode
    [[ -e "$p" ]] || return 1
    while :; do
        owner="$(stat_owner_uid "$p" 2>/dev/null)" || return 1
        mode="$(stat_mode "$p" 2>/dev/null)" || return 1
        [[ "$owner" == 0 ]] || return 1
        (( (8#$mode & 8#022) == 0 )) || return 1
        [[ "$p" == "/" ]] && return 0
        p="$(dirname -- "$p")"
    done
}

require_trusted() {
    local p="$1" what="$2"
    path_is_trusted "$p" && return 0
    cat >&2 <<MSG
error: $what is $p, which is not owned exclusively by root.

  a root-owned helper that runs an interpreter or a binary your own account can
  replace is not a privileged helper. hardening would report success and
  protect nothing, so this installer refuses instead.

  install that dependency under a prefix root owns, or keep using the
  unhardened mode, which is honest about what it does and does not stop.
MSG
    exit 1
}

source_file="$real_home/.local/libexec/agent-secrets-helper"
prefix=/usr/local/libexec
destination="$prefix/agent-secrets-helper"
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

# the interpreter named in the helper's shebang, which is what actually runs as
# root. on macos this is stock /bin/bash 3.2 by design: a homebrew bash would
# fail the trust check below.
interpreter="$(sed -n '1s|^#!\([^ ]*\).*|\1|p' "$source_file")"
[[ -n "$interpreter" ]] || { echo "error: the helper has no shebang" >&2; exit 1; }
require_trusted "$interpreter" "the helper's interpreter"

gpg_bin=""
for candidate in /usr/bin/gpg /usr/bin/gpg2 /opt/local/bin/gpg /usr/local/bin/gpg /opt/homebrew/bin/gpg; do
    [[ -x "$candidate" ]] || continue
    if path_is_trusted "$candidate"; then gpg_bin="$candidate"; break; fi
    [[ -n "${gpg_untrusted:-}" ]] || gpg_untrusted="$candidate"
done
if [[ -z "$gpg_bin" ]]; then
    if [[ -n "${gpg_untrusted:-}" ]]; then
        require_trusted "$gpg_untrusted" "the only gpg on this machine"
    fi
    echo "error: no gpg found. install gnupg first." >&2
    exit 1
fi

# check the prefix before creating anything under it. `install -d` chowns a
# directory that already exists, and on an intel mac /usr/local belongs to
# homebrew: creating the helper directory first would quietly take a piece of
# homebrew's tree and then refuse to harden anyway.
existing="$prefix"
while [[ ! -e "$existing" && "$existing" != "/" ]]; do existing="$(dirname -- "$existing")"; done
require_trusted "$existing" "the install prefix"
install -d -o root -g "$root_group" -m 0755 "$prefix"
require_trusted "$prefix" "the install prefix"

# a sudoers.d drop-in is only a rule if the main sudoers actually reads the
# directory. it does on every distribution and on macos, but a hand-edited
# /etc/sudoers can drop the include line and the failure would be silent.
if ! grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers 2>/dev/null; then
    echo "error: /etc/sudoers does not include /etc/sudoers.d. add '@includedir /etc/sudoers.d' first." >&2
    exit 1
fi

install -o root -g "$root_group" -m 0755 "$source_file" "$destination"
chown "root:$root_group" "$key_file"
chmod 600 "$key_file"

printf '%s ALL=(root) NOPASSWD: %s\n' "$real_user" "$destination" > "$sudoers_file.new"
chmod 440 "$sudoers_file.new"
if ! visudo -cf "$sudoers_file.new" >/dev/null; then
    rm -f "$sudoers_file.new"
    echo "error: sudoers syntax check failed. nothing was installed." >&2
    exit 1
fi
mv -f "$sudoers_file.new" "$sudoers_file"

install -d -o root -g "$root_group" -m 0700 "$runtime_root"
install -d -o root -g "$root_group" -m 0700 "$runtime_root/$uid"

echo "installed the root-owned helper and locked the key"
echo "  helper:      $destination"
echo "  interpreter: $interpreter"
echo "  gpg:         $gpg_bin"
echo "run secret-doctor to inspect the result"
