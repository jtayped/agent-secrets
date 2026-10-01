#!/usr/bin/env bash
# the approval gate: whether a sensitive value can reach a command nobody
# approved it for. a failure here is not a wrong answer or a lost key, it is a
# credential handed over without the dialog that was supposed to stand in front
# of it, and nothing about that looks wrong afterwards.
#
# no test here waits on a dialog. a verdict already in the cache is answered
# without one, so every case below is decided by what the gate finds there:
# an allow it should not honour, or a deny it must not skip past.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export AGENT_SECRETS_DIR="$test_dir/.secrets"
export AGENT_SECRETS_HELPER_INSTALLED="$test_dir/no-installed-helper"
export AGENT_SECRETS_HELPER_LOCAL="$repo_dir/lib/agent-secrets-helper"
export PATH="$repo_dir/bin:$PATH"
export XDG_RUNTIME_DIR="$test_dir/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
gate_cache="$XDG_RUNTIME_DIR/agent-secrets-gate"
helper="$AGENT_SECRETS_HELPER_LOCAL"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# the helper only runs main when executed, so sourcing it in a subshell gives
# the tests its own functions rather than a second implementation of them. its
# last line is `[[ sourced ]] && main`, which leaves a status of 1 behind when
# sourced, and set -e would end the subshell on it.
helper_call() {
    # shellcheck disable=SC1090
    ( source "$helper" || true; "$@" )
}

verdict() {
    mkdir -p "$gate_cache"
    chmod 700 "$gate_cache"
    printf '%s 9999999999\n' "$1" > "$(helper_call verdict_file "$gate_cache" "$2" "$3" "$4")"
}

secret-init >/dev/null
"$helper" encrypt demo > "$AGENT_SECRETS_DIR/scopes/demo.env.gpg" <<'scope'
#@sensitive
#@g pg.prod  production database
PG_PROD_PASS=prod-secret

#@sensitive
#@g pg_prod  scratch credentials
scope
secret-reindex demo >/dev/null

# ---------------------------------------------------------------------------
# an approval belongs to the group it was given for.
#
# verdict files used to be named ${scope}__${id//./_}. pg.prod and pg_prod both
# became demo__pg_prod, so saying yes to the scratch group unlocked production.
# pg_prod holds nothing: both groups derive PG_PROD_, and pg.prod sorts first
# and owns every key. an empty decoy is all it took.
verdict allow demo g pg_prod
verdict deny  demo g pg.prod
secret-run demo pg_prod -- true || fail "an approved group did not open"
rc=0
out="$(secret-run demo pg.prod -- sh -c 'printf %s "$PG_PROD_PASS"' 2>/dev/null)" || rc=$?
[[ "$rc" -eq 77 ]] || fail "approving pg_prod decided pg.prod too (exit $rc)"
[[ "$out" != *prod-secret* ]] || fail "pg.prod was read on an approval given for pg_prod"
rm -rf "$gate_cache"

# the names themselves, so the property does not rest on one pair of spellings.
a="$(helper_call verdict_file /c demo g pg.prod)"
b="$(helper_call verdict_file /c demo g pg_prod)"
[[ "$a" != "$b" ]] || fail "pg.prod and pg_prod share a verdict file"

# a case-insensitive filesystem, which is the macos default, folds names before
# comparing them. a key and a group must still not meet there.
k="$(helper_call verdict_file /c demo k PG_PROD | tr 'A-Z' 'a-z')"
g="$(helper_call verdict_file /c demo g pg_prod | tr 'A-Z' 'a-z')"
[[ "$k" != "$g" ]] || fail "the key PG_PROD and the group pg_prod share a verdict file once case is folded"
k1="$(helper_call verdict_file /c demo k Token | tr 'A-Z' 'a-z')"
k2="$(helper_call verdict_file /c demo k TOKEN | tr 'A-Z' 'a-z')"
[[ "$k1" != "$k2" ]] || fail "two keys differing only in case share a verdict file once case is folded"

# ---------------------------------------------------------------------------
# an approval for a parent does not answer for a child.
#
# the dialog that approves a parent lists every marked group beneath it, so a
# child that existed then was approved by name. one marked afterwards was not,
# and walking up to the parent's verdict let it through anyway.
verdict allow demo g pg
found="$(helper_call cached_verdict demo g pg.prod "$gate_cache")"
[[ -z "$found" ]] || fail "pg.prod took its verdict from pg: '$found'"
rm -rf "$gate_cache"

# ---------------------------------------------------------------------------
# a key marked on its own is gated as a key, whatever its case.
#
# the format accepts lowercase key names. the gate used to decide key or group
# from the first letter, so a lowercase key was looked up as a group.
roots="$(printf '#@sensitive\nlower_key=v\n#@g svc  s\n#@sensitive\nSVC_TOKEN=t\n' \
    | helper_call parse_meta | helper_call sensitive_roots)"
grep -q $'^k\tlower_key\t' <<< "$roots" || fail "a lowercase key marked on its own was not typed as a key: $roots"
grep -q $'^k\tSVC_TOKEN\t' <<< "$roots" || fail "an uppercase key marked on its own was not typed as a key: $roots"

if [[ "$failures" -ne 0 ]]; then
    echo "$failures gate check(s) failed" >&2
    exit 1
fi
echo "gate checks passed"
