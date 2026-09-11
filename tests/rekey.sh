#!/usr/bin/env bash
# secret-rekey rewrites every encrypted file in the store. if it goes wrong you
# find out the next time you need a password, which is the worst possible time.
#
# so this checks the two things that matter: every value survives, and the
# store stays readable no matter where the rekey is interrupted.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export AGENT_SECRETS_DIR="$test_dir/.secrets"
export AGENT_SECRETS_HELPER_INSTALLED="$test_dir/no-installed-helper"
export AGENT_SECRETS_HELPER_LOCAL="$repo_dir/lib/agent-secrets-helper"
export PATH="$repo_dir/bin:$PATH"
helper="$AGENT_SECRETS_HELPER_LOCAL"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

secret-init >/dev/null
key="$AGENT_SECRETS_DIR/key/.key"
old_key="$AGENT_SECRETS_DIR/key/.key.old"

"$helper" encrypt alpha > "$AGENT_SECRETS_DIR/scopes/alpha.env.gpg" <<'scope'
#@g service   apis
SERVICE_TOKEN=alpha-token
#@g service.github   gh
SERVICE_GITHUB_APP_ID=42
LOOSE_ALPHA=loose
scope
"$helper" encrypt beta > "$AGENT_SECRETS_DIR/scopes/beta.env.gpg" <<'scope'
#@g pg   postgres
PG_HOST=db.test
PG_PASSWORD=beta-password
scope
secret-reindex >/dev/null

snapshot() {
    local f name
    for f in "$AGENT_SECRETS_DIR"/scopes/*.env.gpg; do
        name="${f##*/}"
        printf '%s\n' "== $name"
        "$helper" decrypt "${name%.env.gpg}" | grep -E '^[A-Za-z_]' | sort
    done
}
before="$(snapshot)"
key_before="$(cksum < "$key")"

# ---------------------------------------------------------------------------
# the ordinary path.
secret-rekey --yes >/dev/null

[[ "$(cksum < "$key")" != "$key_before" ]] || fail "the key did not change"
[[ -e "$old_key" ]] || fail "the previous key was not kept"
[[ "$(snapshot)" == "$before" ]] || {
    fail "a value changed across the rekey"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$(snapshot)") >&2 || true
}

# the new ciphertext must open with bare gpg under the new key, which is the
# only check that does not go through the code that wrote it.
for f in "$AGENT_SECRETS_DIR"/scopes/*.env.gpg; do
    gpg --quiet --batch --pinentry-mode loopback --passphrase-file "$key" \
        --decrypt "$f" >/dev/null 2>&1 \
        || fail "${f##*/} does not open under the new key with bare gpg"
done

# the index tracks a hash of the ciphertext, so a rekey invalidates it. the
# command is supposed to rebuild it rather than leave every scope stale.
secret-list alpha >/dev/null 2>&1 || fail "the index was left stale after a rekey"

# a second rekey must refuse until the first is finished, or the old key gets
# overwritten and the way back is gone.
if secret-rekey --yes >/dev/null 2>&1; then
    fail "a second rekey ran while an unfinished one was outstanding"
fi

# ---------------------------------------------------------------------------
# finishing removes the old key and leaves everything working.
secret-rekey --finish >/dev/null
[[ ! -e "$old_key" ]] || fail "--finish did not remove the previous key"
[[ "$(snapshot)" == "$before" ]] || fail "a value changed when the rekey was finished"

# ---------------------------------------------------------------------------
# the half-finished state.
#
# between swapping the key and swapping the scopes, the store holds a mix of
# both. that window is the whole reason the old key is kept, so it gets tested
# directly: put the store into exactly that state by hand and confirm every
# scope still opens.
cp "$key" "$old_key"
printf '%s\n' "$(gpg --armor --gen-random 2 32)" > "$key"
chmod 600 "$key"
# alpha moves to the new key, beta stays on the old one.
"$helper" decrypt alpha > "$test_dir/alpha.plain"
gpg --quiet --batch --yes --pinentry-mode loopback --passphrase-file "$key" \
    --symmetric --cipher-algo AES256 < "$test_dir/alpha.plain" \
    > "$AGENT_SECRETS_DIR/scopes/alpha.env.gpg"
secret-reindex >/dev/null 2>&1 || true

for scope in alpha beta; do
    "$helper" decrypt "$scope" >/dev/null 2>&1 \
        || fail "$scope became unreadable in the middle of a rekey"
done
[[ "$(snapshot)" == "$before" ]] || fail "a value was lost in the middle of a rekey"

# a fresh rekey must refuse from that state: generating another key would
# overwrite the old one and strand whatever still needs it.
if secret-rekey --yes >/dev/null 2>&1; then
    fail "a fresh rekey ran while scopes still needed the old key"
fi

# --resume is the way out, and it must use the keys already on disk.
key_mid="$(cksum < "$key")"
secret-rekey --resume >/dev/null
[[ "$(cksum < "$key")" == "$key_mid" ]] || fail "--resume generated a new key instead of using the current one"
[[ "$(snapshot)" == "$before" ]] || fail "resuming an interrupted rekey lost a value"
secret-rekey --finish >/dev/null
[[ ! -e "$old_key" ]] || fail "--finish did not remove the old key after a resume"

# ---------------------------------------------------------------------------
# --finish must refuse while anything still needs the old key, since removing
# it then would destroy that scope for good.
cp "$key" "$old_key"
printf '%s\n' "$(gpg --armor --gen-random 2 32)" > "$key"
chmod 600 "$key"
if secret-rekey --finish >/dev/null 2>&1; then
    fail "--finish removed the old key while scopes still needed it"
fi
[[ -e "$old_key" ]] || fail "--finish deleted the old key despite refusing"

# put the store back so the trap cleans up a sane thing.
mv -f "$old_key" "$key"

if [[ "$failures" -gt 0 ]]; then
    echo "rekey test: $failures failure(s)" >&2
    exit 1
fi
echo "rekey test passed"
