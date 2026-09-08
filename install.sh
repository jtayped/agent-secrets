#!/usr/bin/env bash
# install the user-facing commands for the account running this script.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
lib_dir="${XDG_LIB_HOME:-$HOME/.local/libexec}"
source_dir="$lib_dir/agent-secrets"

command -v gpg >/dev/null || {
    echo "error: gpg is required. install gnupg first." >&2
    exit 1
}
command -v install >/dev/null || {
    echo "error: this installer needs the install command." >&2
    exit 1
}

install -d -m 700 "$bin_dir" "$lib_dir" "$source_dir"
for command in secret-init secret-list secret-edit secret-set secret-approve secret-run secret-reindex pg-hosts ssh-hosts secrets-bisync secret-helper-status; do
    install -m 755 "$repo_dir/bin/$command" "$bin_dir/$command"
done
install -m 644 "$repo_dir/bin/secret-common.sh" "$bin_dir/secret-common.sh"
install -m 755 "$repo_dir/lib/agent-secrets-helper" "$lib_dir/agent-secrets-helper"
install -m 755 "$repo_dir/install-root.sh" "$lib_dir/agent-secrets-install-root"
install -m 644 "$repo_dir/systemd/secrets-bisync.service" "$source_dir/secrets-bisync.service"
install -m 644 "$repo_dir/systemd/secrets-bisync.timer" "$source_dir/secrets-bisync.timer"

"$bin_dir/secret-init"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "add $bin_dir to your path before opening a new shell." ;;
esac
echo "installed the commands under $bin_dir"
echo "run secret-edit example --new to create your first encrypted scope"
echo "run sudo $lib_dir/agent-secrets-install-root to protect the key with root ownership"
