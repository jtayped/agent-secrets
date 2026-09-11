#!/usr/bin/env bash
# install the user-facing commands for the account running this script.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
lib_dir="${XDG_LIB_HOME:-$HOME/.local/libexec}"
source_dir="$lib_dir/agent-secrets"

os="$(uname -s)"
case "$os" in
    Linux|Darwin) ;;
    CYGWIN*|MINGW*|MSYS*)
        cat >&2 <<'MSG'
error: windows is not supported natively.

  agent-secrets is a set of bash programs whose protection comes from posix file
  ownership, sudo, and a root-owned helper. none of those exist on windows in a
  form this design could use, so a git-bash install would look like it worked
  and protect nothing.

  install it inside wsl2 instead. from a wsl2 shell the linux instructions apply
  unchanged, including the hardening step.
MSG
        exit 1 ;;
    *) echo "error: unsupported platform: $os (linux and macos only)" >&2; exit 1 ;;
esac

missing=""
for command in gpg install awk sed mktemp; do
    command -v "$command" >/dev/null || missing="$missing $command"
done
if [[ "$os" == Darwin ]]; then
    command -v shasum >/dev/null || missing="$missing shasum"
else
    command -v sha256sum >/dev/null || missing="$missing sha256sum"
fi
if [[ -n "$missing" ]]; then
    echo "error: missing required commands:$missing" >&2
    [[ "$missing" == *gpg* ]] && echo "  install gnupg, then run this again." >&2
    exit 1
fi

install -d -m 700 "$bin_dir" "$lib_dir" "$source_dir"
for command in secret-init secret-list secret-edit secret-set secret-approve secret-run \
               secret-reindex secret-doctor secret-update secret-rekey pg-hosts ssh-hosts \
               secrets-bisync secret-helper-status; do
    install -m 755 "$repo_dir/bin/$command" "$bin_dir/$command"
done
install -m 644 "$repo_dir/bin/secret-common.sh" "$bin_dir/secret-common.sh"
install -m 755 "$repo_dir/lib/agent-secrets-helper" "$lib_dir/agent-secrets-helper"
install -m 755 "$repo_dir/install-root.sh" "$lib_dir/agent-secrets-install-root"
install -m 644 "$repo_dir/systemd/secrets-bisync.service" "$source_dir/secrets-bisync.service"
install -m 644 "$repo_dir/systemd/secrets-bisync.timer" "$source_dir/secrets-bisync.timer"

# the manifest is what lets secret-update find this checkout again, and what
# tells you which commit you are actually running when something misbehaves.
# it is written next to the commands so it is found wherever they were
# installed, without secret-common.sh having to guess at xdg paths.
version="$(tr -d '[:space:]' < "$repo_dir/VERSION")"
commit=""
if git -C "$repo_dir" rev-parse --short HEAD >/dev/null 2>&1; then
    commit="$(git -C "$repo_dir" rev-parse --short HEAD)"
fi
umask 077
cat > "$bin_dir/secret-manifest" <<MANIFEST
version=$version
source=$repo_dir
commit=$commit
installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST
chmod 644 "$bin_dir/secret-manifest"

# this installer writes to $bin_dir and $lib_dir only. the one thing it runs
# that goes near the store is secret-init, which creates what is missing and
# refuses to replace a key that already exists.
"$bin_dir/secret-init"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "add $bin_dir to your path before opening a new shell." ;;
esac

# an older copy of these commands earlier on PATH wins every lookup, and the
# result is a mixed install: the commands that existed back then come from the
# old copy, the ones added since come from this one. that is worse than either
# version on its own, and nothing about it looks wrong until something behaves
# like a version you are not reading. so say so, loudly, and name the files.
shadowed=""
for command in "$bin_dir"/secret-* "$bin_dir"/pg-hosts "$bin_dir"/ssh-hosts; do
    [[ -e "$command" ]] || continue
    name="${command##*/}"
    found="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$found" && "$found" != "$command" ]] && shadowed="$shadowed  $found
"
done
if [[ -n "$shadowed" ]]; then
    echo
    echo "warning: these copies come earlier on your path and will be used instead:"
    printf "$shadowed"
    echo
    echo "  they are from an older install. running a mix of the two is worse than"
    echo "  running either, because the commands that existed back then come from the"
    echo "  old copy and the rest come from this one."
    echo
    echo "  delete them, or put $bin_dir earlier on your path."
fi
echo "installed agent-secrets $version under $bin_dir"
echo "run secret-edit example --new to create your first encrypted scope"
echo "run secret-doctor to see what this machine supports"
echo "run sudo $lib_dir/agent-secrets-install-root to protect the key with root ownership"
