#!/usr/bin/env bash
# properties of the scope format, which is where secrets get lost quietly.
#
# every save goes through cmd_encrypt, which reparses the payload and rebuilds
# it from the meta stream. that is a full decode/re-encode of your data on
# every edit. if the renderer ever fails to emit a key it parsed, the key is
# gone from the file and there is no error: the save succeeds, the index
# rebuilds, and nothing looks wrong until you need the value.
#
# so these are the strongest properties the code supports, in the usual order:
# invariant (nothing lost), idempotence (canonicalising twice is canonicalising
# once), and round-trip against an oracle that is not this codebase.
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

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# decrypt without going through this project's own reader. the format doc
# promises that a ciphertext backup plus the key is enough to recover
# everything with no tooling at all, and a round-trip checked with the same
# code that wrote the file cannot tell you whether that is true.
oracle_decrypt() {
    gpg --quiet --batch --pinentry-mode loopback --passphrase-file "$key" --decrypt "$1" 2>/dev/null
}

vars_of()  { grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/=$//' | sort; }

# ---------------------------------------------------------------------------
# 1. no declared key may disappear through a save.
payload="$test_dir/payload.env"
cat > "$payload" <<'ENV'
#@g pg   postgres
PG_SSLMODE=require
#@g pg.aws   rds
PG_AWS_HOST=h
PG_AWS_PORT=5432
#@sensitive
#@g pg.aws.app   role
PG_AWS_APP_USER=app
PG_AWS_APP_PASSWORD=pw
#@g service   apis
SERVICE_STRIPE_KEY=sk
#@g service.github   gh
SERVICE_GITHUB_APP_ID=1
UNGROUPED_TOKEN=loose
ANOTHER_LOOSE_ONE=also-loose
ENV

"$helper" encrypt roundtrip < "$payload" > "$AGENT_SECRETS_DIR/scopes/roundtrip.env.gpg"
want="$(vars_of < "$payload")"
got="$(oracle_decrypt "$AGENT_SECRETS_DIR/scopes/roundtrip.env.gpg" | vars_of)"
if [[ "$want" != "$got" ]]; then
    fail "a save changed the set of keys"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
fi

# ungrouped keys are the ones most at risk: the renderer emits them from a
# separate branch that only runs when no group filter is in play.
grep -q '^UNGROUPED_TOKEN=loose$' <<< "$(oracle_decrypt "$AGENT_SECRETS_DIR/scopes/roundtrip.env.gpg")" \
    || fail "an ungrouped key did not survive a save"

# ---------------------------------------------------------------------------
# 2. values must survive byte for byte.
#
# the renderer splits each line at the first '=' and reassembles it. anything
# that makes a value look like syntax is a candidate for being eaten.
values_file="$test_dir/values.env"
{
    printf '#@g awkward  values that look like syntax\n'
    printf 'AWKWARD_EQUALS=a=b=c\n'
    printf 'AWKWARD_HASH=value#not-a-comment\n'
    printf 'AWKWARD_SPACES=two  spaces  inside\n'
    printf 'AWKWARD_TRAILING=trailing-space \n'
    printf 'AWKWARD_LEADING= leading-space\n'
    printf 'AWKWARD_QUOTES=he said "hi" and '"'"'bye'"'"'\n'
    printf 'AWKWARD_DOLLAR=$HOME and ${NOT_EXPANDED} and `cmd`\n'
    printf 'AWKWARD_BACKSLASH=a\\b\\\\c\n'
    printf 'AWKWARD_UNICODE=café — naïve — 日本語 — 🔑\n'
    printf 'AWKWARD_AT=#@g looks like a directive\n'
    printf 'AWKWARD_EMPTY=\n'
    printf 'AWKWARD_LONG=%s\n' "$(head -c 2000 /dev/zero | tr '\0' 'x')"
    printf 'AWKWARD_TABS=a\tb\n'
} > "$values_file"

"$helper" encrypt values < "$values_file" > "$AGENT_SECRETS_DIR/scopes/values.env.gpg"
decoded="$(oracle_decrypt "$AGENT_SECRETS_DIR/scopes/values.env.gpg")"
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    var="${line%%=*}"
    expected="${line#*=}"
    # presence first. an empty value and a missing key compare equal once the
    # prefix is stripped, so without this the empty-value case passes whether
    # the key survived or not.
    if ! grep -q "^$var=" <<< "$decoded"; then
        fail "$var vanished from the scope entirely"
        continue
    fi
    actual="$(grep -m1 "^$var=" <<< "$decoded" || true)"
    actual="${actual#*=}"
    if [[ "$actual" != "$expected" ]]; then
        fail "value of $var changed: wanted [$expected] got [$actual]"
    fi
done < "$values_file"

# ---------------------------------------------------------------------------
# 3. canonicalising is idempotent.
#
# if it is not, every save churns the file, which makes real changes
# impossible to see and makes the next splice unpredictable.
once="$(oracle_decrypt "$AGENT_SECRETS_DIR/scopes/roundtrip.env.gpg")"
printf '%s\n' "$once" | "$helper" encrypt twice > "$test_dir/twice.gpg"
twice="$(oracle_decrypt "$test_dir/twice.gpg")"
[[ "$once" == "$twice" ]] || {
    fail "canonicalising twice differs from canonicalising once"
    diff <(printf '%s\n' "$once") <(printf '%s\n' "$twice") >&2 || true
}

# ---------------------------------------------------------------------------
# 4. the reverse oracle: a payload this project did not encrypt must still be
# readable by it. otherwise the tool depends on quirks of its own writer, and
# the recovery story in docs/format.md is not real.
printf '#@g plain  written by bare gpg\nPLAIN_TOKEN=from-outside\n' \
    | gpg --quiet --batch --yes --pinentry-mode loopback --passphrase-file "$key" \
          --symmetric --cipher-algo AES256 > "$AGENT_SECRETS_DIR/scopes/plain.env.gpg"
secret-reindex plain >/dev/null 2>&1 || fail "could not index a scope written by bare gpg"
[[ "$(secret-run plain plain -- bash -c 'printf "%s" "$PLAIN_TOKEN"' 2>/dev/null)" == from-outside ]] \
    || fail "a scope written by bare gpg was not readable by the tool"

# ---------------------------------------------------------------------------
# 5. group assignment is longest-prefix, and a key may not end up unreachable.
"$helper" index roundtrip > "$test_dir/toc" 2>/dev/null || true
assigned() { awk -F'\t' -v v="$1" '$1=="K" && $2==v { print $3 }' "$test_dir/toc"; }
[[ "$(assigned PG_AWS_APP_USER)" == "pg.aws.app" ]] \
    || fail "PG_AWS_APP_USER went to [$(assigned PG_AWS_APP_USER)], not pg.aws.app"
[[ "$(assigned PG_AWS_HOST)" == "pg.aws" ]] \
    || fail "PG_AWS_HOST went to [$(assigned PG_AWS_HOST)], not pg.aws"
[[ "$(assigned PG_SSLMODE)" == "pg" ]] \
    || fail "PG_SSLMODE went to [$(assigned PG_SSLMODE)], not pg"
[[ -z "$(assigned UNGROUPED_TOKEN)" ]] \
    || fail "UNGROUPED_TOKEN was claimed by [$(assigned UNGROUPED_TOKEN)]"

# every key in the payload must appear in the index. a key the index cannot
# see is a key no command can find.
# awk rather than grep: bsd grep has no -P, and a literal tab in a pattern is
# the kind of thing an editor silently turns into spaces.
for var in $want; do
    awk -F'\t' -v v="$var" '$1=="K" && $2==v { found=1 } END { exit !found }' "$test_dir/toc" \
        || fail "$var is missing from the index"
done

# ---------------------------------------------------------------------------
# 6. a payload with metadata errors must be refused, not half-written.
if printf '#@g Bad.Path  uppercase is invalid\nX=1\n' | "$helper" encrypt broken > "$test_dir/broken.gpg" 2>/dev/null; then
    fail "a scope with a bad group path was written anyway"
fi
if printf 'not a key value line\n' | "$helper" encrypt broken2 > "$test_dir/broken2.gpg" 2>/dev/null; then
    fail "a payload with a non-assignment line was written anyway"
fi

# ---------------------------------------------------------------------------
if [[ "$failures" -gt 0 ]]; then
    echo "format test: $failures failure(s)" >&2
    exit 1
fi
echo "format test passed"
