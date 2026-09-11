#!/usr/bin/env bash
# the key is the one thing in this system with no recovery path. everything
# else can be rebuilt from the scopes; a lost or silently weakened key loses
# every secret permanently. so this file tests the key on its own.
#
# the bug that prompted it: the key used to be 32 raw random bytes, and gpg
# reads a passphrase file as text and stops at the first newline. one key in
# eight contained a 0x0a somewhere and quietly had less entropy than intended;
# one in 256 began with one and produced a store that could never be read.
# both failures were silent, and secret-init reported success either way.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export AGENT_SECRETS_HELPER_INSTALLED="$test_dir/no-installed-helper"
export AGENT_SECRETS_HELPER_LOCAL="$repo_dir/lib/agent-secrets-helper"
export PATH="$repo_dir/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# a generated key must survive being read as text.
#
# one key would pass this by luck about seven times in eight, which is exactly
# how the original bug stayed hidden. the loop is the test.
rounds=64
echo "generating $rounds keys"
for i in $(seq 1 "$rounds"); do
    export AGENT_SECRETS_DIR="$test_dir/store-$i"
    secret-init >/dev/null
    key="$AGENT_SECRETS_DIR/key/.key"

    bytes="$(wc -c < "$key" | tr -d ' ')"
    first="$(head -1 "$key" | wc -c | tr -d ' ')"

    # gpg takes the first line and stops. if there is anything after it, the
    # rest of the key is decoration.
    [[ "$first" -eq "$bytes" ]] \
        || fail "key $i: gpg would use $((first - 1)) of $bytes bytes"
    [[ "$first" -gt 1 ]] \
        || fail "key $i: first line is empty, so the passphrase is empty"
    [[ "$((bytes - 1))" -ge 43 ]] \
        || fail "key $i: only $((bytes - 1)) characters, too short for 256 bits"
    if LC_ALL=C grep -q '[^A-Za-z0-9+/=]' <<< "$(head -1 "$key")"; then
        fail "key $i: contains a character outside the base64 alphabet"
    fi
    # a NUL truncates a passphrase exactly like a newline does. bash cannot
    # carry one in a variable, so this counts bytes instead of matching.
    stripped="$(tr -d '\0' < "$key" | wc -c | tr -d ' ')"
    [[ "$stripped" -eq "$bytes" ]] || fail "key $i: contains a NUL byte"
done

# ---------------------------------------------------------------------------
# a generated key must actually work, end to end. checking its shape is not
# the same as checking that gpg accepts it.
export AGENT_SECRETS_DIR="$test_dir/store-1"
"$AGENT_SECRETS_HELPER_LOCAL" encrypt demo > "$AGENT_SECRETS_DIR/scopes/demo.env.gpg" <<'scope'
#@g service.api  round trip
SERVICE_API_TOKEN=survives
scope
secret-reindex demo >/dev/null
[[ "$(secret-run demo service.api -- bash -c 'printf "%s" "$SERVICE_API_TOKEN"')" == survives ]] \
    || fail "a freshly generated key could not round-trip a scope"

# ---------------------------------------------------------------------------
# secret-init must never replace a key. this is the single most destructive
# thing the tool could do, and it is one stray mv away.
before="$(cksum < "$AGENT_SECRETS_DIR/key/.key")"
secret-init >/dev/null
secret-init >/dev/null
[[ "$(cksum < "$AGENT_SECRETS_DIR/key/.key")" == "$before" ]] \
    || fail "secret-init replaced an existing key"

# and the scope encrypted under it still opens afterwards.
[[ "$(secret-run demo service.api -- bash -c 'printf "%s" "$SERVICE_API_TOKEN"')" == survives ]] \
    || fail "a scope stopped decrypting after secret-init ran again"

# ---------------------------------------------------------------------------
# secret-doctor has to notice a weakened key rather than call it fine. this is
# the check for the ~1 in 8 keys generated before the fix.
export AGENT_SECRETS_DIR="$test_dir/legacy"
mkdir -p "$AGENT_SECRETS_DIR/key" "$AGENT_SECRETS_DIR/scopes" "$AGENT_SECRETS_DIR/index"
chmod 700 "$AGENT_SECRETS_DIR" "$AGENT_SECRETS_DIR/key"
printf 'AAAAAAAAAA\nBBBBBBBBBBBBBBBBBBBBBB' > "$AGENT_SECRETS_DIR/key/.key"
chmod 600 "$AGENT_SECRETS_DIR/key/.key"
doctor="$(secret-doctor 2>&1 || true)"
grep -q 'key strength' <<< "$doctor" \
    || fail "secret-doctor did not report a key truncated by a newline"

printf '\nBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' > "$AGENT_SECRETS_DIR/key/.key"
doctor="$(secret-doctor 2>&1 || true)"
grep -q 'first line of' <<< "$doctor" \
    || fail "secret-doctor did not report a key whose first line is empty"

echo "key test passed"
