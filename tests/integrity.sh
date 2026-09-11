#!/usr/bin/env bash
# the destructive paths: every place a command replaces a file that holds
# secrets. these are the operations where a bug does not produce a wrong
# answer, it produces a shorter store.
#
# the last section is a mutation test. it sabotages the renderer inside a copy
# of the helper and asserts the save is refused, which is the only way to show
# that the runtime key-loss guard actually fires rather than merely existing.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export AGENT_SECRETS_DIR="$test_dir/.secrets"
export AGENT_SECRETS_HELPER_INSTALLED="$test_dir/no-installed-helper"
export AGENT_SECRETS_HELPER_LOCAL="$repo_dir/lib/agent-secrets-helper"
export PATH="$repo_dir/bin:$PATH"
helper="$AGENT_SECRETS_HELPER_LOCAL"

secret-init >/dev/null
key="$AGENT_SECRETS_DIR/key/.key"
scope_file="$AGENT_SECRETS_DIR/scopes/demo.env.gpg"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
plaintext() {
    gpg --quiet --batch --pinentry-mode loopback --passphrase-file "$key" --decrypt "$1" 2>/dev/null
}

seed() {
    "$helper" encrypt demo > "$scope_file" <<'scope'
#@g pg   postgres
PG_SSLMODE=require
#@g pg.aws   rds
PG_AWS_HOST=original-host
PG_AWS_PORT=5432
#@g service   apis
SERVICE_TOKEN=original-token
SERVICE_TOKEN_ID=a-different-key
#@g service.github   gh
SERVICE_GITHUB_APP_ID=1
LOOSE_KEY=loose-value
scope
    secret-reindex demo >/dev/null
}
seed
all_keys="$(plaintext "$scope_file" | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/=$//' | sort)"

# ---------------------------------------------------------------------------
# editing one group must not touch anything outside it.
#
# edit-merge rebuilds the whole scope from "everything except this subtree"
# plus the edited subtree. a mistake in the exclusion half deletes the rest of
# the file, and the command still reports success.
printf '#@g pg.aws   rds\nPG_AWS_HOST=edited-host\nPG_AWS_PORT=5432\n' \
    | "$helper" edit-merge demo pg.aws > "$scope_file.new"
mv -f "$scope_file.new" "$scope_file"
after="$(plaintext "$scope_file")"

for var in $all_keys; do
    grep -q "^$var=" <<< "$after" || fail "editing pg.aws lost $var"
done
grep -q '^PG_AWS_HOST=edited-host$'   <<< "$after" || fail "the edit itself did not take"
grep -q '^SERVICE_TOKEN=original-token$' <<< "$after" || fail "a sibling group's value changed"
grep -q '^LOOSE_KEY=loose-value$'     <<< "$after" || fail "an ungrouped key was lost by a group edit"

# editing a leaf group must not swallow its parent's own keys.
seed
printf '#@g service.github   gh\nSERVICE_GITHUB_APP_ID=2\n' \
    | "$helper" edit-merge demo service.github > "$scope_file.new"
mv -f "$scope_file.new" "$scope_file"
after="$(plaintext "$scope_file")"
grep -q '^SERVICE_TOKEN=original-token$' <<< "$after" \
    || fail "editing service.github lost the parent group's key"
for var in $all_keys; do
    grep -q "^$var=" <<< "$after" || fail "editing service.github lost $var"
done

# ---------------------------------------------------------------------------
# secret-set must replace exactly one key.
#
# SERVICE_TOKEN and SERVICE_TOKEN_ID share a prefix. a substring match instead
# of an exact one silently rewrites the wrong secret.
seed
printf 'replaced' | secret-set demo service.token --force >/dev/null
after="$(plaintext "$scope_file")"
grep -q '^SERVICE_TOKEN=replaced$'            <<< "$after" || fail "--force did not replace the target key"
grep -q '^SERVICE_TOKEN_ID=a-different-key$'  <<< "$after" || fail "--force also rewrote a key sharing its prefix"
for var in $all_keys; do
    grep -q "^$var=" <<< "$after" || fail "secret-set lost $var"
done

# and it must refuse to overwrite without --force.
if printf 'sneaky' | secret-set demo service.token >/dev/null 2>&1; then
    fail "secret-set overwrote an existing key without --force"
fi
grep -q '^SERVICE_TOKEN=replaced$' <<< "$(plaintext "$scope_file")" \
    || fail "a refused secret-set still changed the value"

# ---------------------------------------------------------------------------
# a refused write must leave the original scope byte-identical.
seed
before_sum="$(cksum < "$scope_file")"
printf 'x' | secret-set demo service.token >/dev/null 2>&1 || true
[[ "$(cksum < "$scope_file")" == "$before_sum" ]] || fail "a refused secret-set modified the scope file"

# so must a payload the helper rejects.
if printf 'this is not an assignment\n' | "$helper" encrypt demo > "$scope_file.new" 2>/dev/null; then
    fail "the helper encrypted a malformed payload"
fi
rm -f "$scope_file.new"
[[ "$(cksum < "$scope_file")" == "$before_sum" ]] || fail "a rejected payload modified the scope file"

# ---------------------------------------------------------------------------
# the index is published as value-free. if a value ever reaches it, a file
# meant to be safe to read becomes a file that leaks.
seed
for value in original-host original-token loose-value require a-different-key; do
    if grep -qF "$value" "$AGENT_SECRETS_DIR/index/demo.toc"; then
        fail "the value '$value' appears in the index"
    fi
done

# ---------------------------------------------------------------------------
# mutation test: break the renderer and confirm the save is refused.
#
# without this, the key-loss guard in cmd_encrypt is untested code that looks
# reassuring. the sabotage drops every key belonging to a group, which is what
# a plausible regression in the emit loop would do.
sabotaged="$test_dir/sabotaged-helper"
sed 's|for (i = 0; i < nk; i++) if (kg\[i\] == gp\[g\] \&\& has\[kv\[i\]\]) emit_key(i)|# sabotaged for the mutation test|' \
    "$helper" > "$sabotaged"
chmod 755 "$sabotaged"
if ! cmp -s "$helper" "$sabotaged"; then
    if "$sabotaged" encrypt demo < <(plaintext "$scope_file") > "$test_dir/sabotaged.gpg" 2>"$test_dir/sabotaged.err"; then
        fail "a renderer that drops every grouped key still produced a scope"
    else
        grep -q 'loses keys' "$test_dir/sabotaged.err" \
            || fail "the save was refused, but not by the key-loss guard: $(head -2 "$test_dir/sabotaged.err")"
    fi
else
    fail "the mutation test did not modify the helper; its sed pattern needs updating"
fi

# the sabotaged copy must not have touched the real store on its way out.
secret-reindex demo >/dev/null
[[ "$(secret-run demo pg.aws -- bash -c 'printf "%s" "$PG_AWS_HOST"')" == original-host ]] \
    || fail "the scope stopped working after the integrity run"

# ---------------------------------------------------------------------------
if [[ "$failures" -gt 0 ]]; then
    echo "integrity test: $failures failure(s)" >&2
    exit 1
fi
echo "integrity test passed"
