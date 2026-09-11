#!/usr/bin/env bash
# path_is_trusted decides whether hardening is allowed at all. a false yes
# would install a root helper that runs a binary you can replace, which is
# worse than not hardening because it reports success. a false no locks people
# out of hardening entirely, which is what happened: /bin is a symlink on every
# usr-merged distribution, a symlink's mode is always 0777 because the kernel
# ignores it, and reading that as world-writable refused /bin/bash on arch,
# fedora, debian and ubuntu alike.
#
# the helper guards `main` behind BASH_SOURCE so it can be sourced for this.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export AGENT_SECRETS_DIR="$test_dir/.secrets"
# shellcheck source=/dev/null
source "$repo_dir/lib/agent-secrets-helper" || true
set +e

failures=0
trusted()   { if path_is_trusted "$1"; then :; else echo "FAIL: $1 should be trusted but was refused" >&2; failures=$((failures+1)); fi; }
untrusted() { if path_is_trusted "$1"; then echo "FAIL: $1 should be refused but was trusted" >&2; failures=$((failures+1)); fi; }

# real system binaries, however the distribution arranges them. on a usr-merged
# system /bin and /sbin are symlinks; on an older one they are real
# directories. both must pass.
for p in /bin/sh /usr/bin/env; do
    [[ -e "$p" ]] && trusted "$p"
done
[[ -e /bin/bash ]] && trusted /bin/bash

# anything this account can write must be refused, or hardening is theatre.
untrusted "$HOME"
untrusted "$test_dir"
mkdir -p "$test_dir/mine"
untrusted "$test_dir/mine"

# a world-writable directory is refused even when root owns it, which is the
# /tmp case and the reason the mode check exists at all.
[[ -d /tmp ]] && untrusted /tmp

# a path that does not exist is not trusted.
untrusted "$test_dir/nothing-here"

# a symlink pointing somewhere untrustworthy must be refused even though the
# link itself lives in a fine place. this is the case the mode skip could have
# opened up if the target were not walked as well.
ln -s "$test_dir/mine" "$test_dir/link-to-mine"
untrusted "$test_dir/link-to-mine"

if [[ "$failures" -gt 0 ]]; then
    echo "trust test: $failures failure(s)" >&2
    exit 1
fi
echo "trust test passed"
