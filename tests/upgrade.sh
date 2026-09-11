#!/usr/bin/env bash
# the claim secret-update exists to make is that an upgrade cannot touch your
# secrets. this test is that claim, checked: install into a throwaway prefix,
# fingerprint every byte of the store, install again over the top, and compare.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export AGENT_SECRETS_DIR="$test_dir/.secrets"
export XDG_BIN_HOME="$test_dir/bin"
export XDG_LIB_HOME="$test_dir/libexec"
export AGENT_SECRETS_HELPER_INSTALLED="$test_dir/no-installed-helper"
export AGENT_SECRETS_HELPER_LOCAL="$test_dir/libexec/agent-secrets-helper"
export PATH="$XDG_BIN_HOME:$PATH"

fingerprint() {
    # content and metadata: a migration that quietly reindexed or re-encrypted
    # a scope would change one or the other.
    find "$AGENT_SECRETS_DIR" -type f ! -path '*/backups/*' -print0 \
        | sort -z \
        | while IFS= read -r -d '' f; do
              printf '%s %s\n' "${f#"$AGENT_SECRETS_DIR"}" "$(cksum < "$f")"
          done
}

echo "installing"
"$repo_dir/install.sh" >/dev/null

"$XDG_LIB_HOME/agent-secrets-helper" encrypt demo > "$AGENT_SECRETS_DIR/scopes/demo.env.gpg" <<'scope'
#@sensitive
#@g service.api  credentials that must survive an upgrade
SERVICE_API_TOKEN=do-not-lose-me
#@g pg.demo  an endpoint
PG_DEMO_HOST=db.test
scope
secret-reindex demo >/dev/null

before="$(fingerprint)"
key_before="$(cksum < "$AGENT_SECRETS_DIR/key/.key")"
[[ -n "$before" ]]

echo "reinstalling over the top"
"$repo_dir/install.sh" >/dev/null

after="$(fingerprint)"
key_after="$(cksum < "$AGENT_SECRETS_DIR/key/.key")"

if [[ "$before" != "$after" ]]; then
    echo "a reinstall changed the store:" >&2
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
    exit 1
fi
[[ "$key_before" == "$key_after" ]] || { echo "a reinstall replaced the key" >&2; exit 1; }

# the scope still decrypts to the same thing, which is the point of all of it.
value="$(secret-run demo service.api -- bash -c 'printf "%s" "$SERVICE_API_TOKEN"')"
[[ "$value" == "do-not-lose-me" ]] || { echo "value did not survive the upgrade" >&2; exit 1; }

# a store with no recorded version is version 0 and gets adopted, not rewritten.
rm -f "$AGENT_SECRETS_DIR/.store-version"
[[ "$(secret-update --check | grep -c '1 pending')" -eq 1 ]]
secret-update --yes >/dev/null
[[ "$(tr -d '[:space:]' < "$AGENT_SECRETS_DIR/.store-version")" == "1" ]]

after_migration="$(fingerprint)"
if [[ "$before" != "$after_migration" ]]; then
    echo "the migration changed the store beyond its version marker:" >&2
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after_migration") >&2 || true
    exit 1
fi
value="$(secret-run demo service.api -- bash -c 'printf "%s" "$SERVICE_API_TOKEN"')"
[[ "$value" == "do-not-lose-me" ]]

# --check has to be inert.
before_check="$(fingerprint)"
secret-update --check >/dev/null
[[ "$before_check" == "$(fingerprint)" ]]

echo "upgrade test passed"
