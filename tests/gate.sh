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

# verdict <allow|deny> <scope> <g|k> <id> <read|change>
verdict() {
    mkdir -p "$gate_cache"
    chmod 700 "$gate_cache"
    printf '%s 9999999999\n' "$1" > "$(helper_call verdict_file "$gate_cache" "$2" "$3" "$4" "$5")"
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
verdict allow demo g pg_prod read
verdict deny  demo g pg.prod read
secret-run demo pg_prod -- true || fail "an approved group did not open"
rc=0
out="$(secret-run demo pg.prod -- sh -c 'printf %s "$PG_PROD_PASS"' 2>/dev/null)" || rc=$?
[[ "$rc" -eq 77 ]] || fail "approving pg_prod decided pg.prod too (exit $rc)"
[[ "$out" != *prod-secret* ]] || fail "pg.prod was read on an approval given for pg_prod"
rm -rf "$gate_cache"

# the names themselves, so the property does not rest on one pair of spellings.
a="$(helper_call verdict_file /c demo g pg.prod read)"
b="$(helper_call verdict_file /c demo g pg_prod read)"
[[ "$a" != "$b" ]] || fail "pg.prod and pg_prod share a verdict file"

# a case-insensitive filesystem, which is the macos default, folds names before
# comparing them. a key and a group must still not meet there.
k="$(helper_call verdict_file /c demo k PG_PROD read | tr 'A-Z' 'a-z')"
g="$(helper_call verdict_file /c demo g pg_prod read | tr 'A-Z' 'a-z')"
[[ "$k" != "$g" ]] || fail "the key PG_PROD and the group pg_prod share a verdict file once case is folded"
k1="$(helper_call verdict_file /c demo k Token read | tr 'A-Z' 'a-z')"
k2="$(helper_call verdict_file /c demo k TOKEN read | tr 'A-Z' 'a-z')"
[[ "$k1" != "$k2" ]] || fail "two keys differing only in case share a verdict file once case is folded"

# ---------------------------------------------------------------------------
# an approval for a parent does not answer for a child.
#
# the dialog that approves a parent lists every marked group beneath it, so a
# child that existed then was approved by name. one marked afterwards was not,
# and walking up to the parent's verdict let it through anyway.
verdict allow demo g pg read
found="$(helper_call cached_verdict demo g pg.prod "$gate_cache" read)"
[[ -z "$found" ]] || fail "pg.prod took its verdict from pg: '$found'"
rm -rf "$gate_cache"

# ---------------------------------------------------------------------------
# a read and a change are different answers.
#
# approving a write used to cache the same verdict a read uses, so storing one
# value in pg.prod also let anything read pg.prod for the next fifteen minutes.
# each case pairs an allow of one kind with a deny of the other: if the gate
# took the wrong one, the allow would let the operation through.
plain() {
    gpg --quiet --batch --pinentry-mode loopback \
        --passphrase-file "$AGENT_SECRETS_DIR/key/.key" --decrypt "$AGENT_SECRETS_DIR/scopes/demo.env.gpg" 2>/dev/null
}
verdict allow demo g pg.prod read
verdict deny  demo g pg.prod change
secret-run demo pg.prod -- true || fail "a read allow did not open a read"
if printf 'rotated' | secret-set demo pg.prod.PASS --force >/dev/null 2>&1; then
    fail "a read allow let a value be written into pg.prod"
fi
grep -q '^PG_PROD_PASS=prod-secret$' <<< "$(plain)" || fail "a refused write still changed the value"
rm -rf "$gate_cache"

verdict allow demo g pg.prod change
verdict deny  demo g pg.prod read
printf 'rotated' | secret-set demo pg.prod.PASS --force >/dev/null || fail "a change allow did not let a write through"
grep -q '^PG_PROD_PASS=rotated$' <<< "$(plain)" || fail "the approved write did not land"
if secret-run demo pg.prod -- true 2>/dev/null; then
    fail "a change allow let pg.prod be read"
fi
rm -rf "$gate_cache"

# opening a group to edit it hands over its values and saves them back, so it
# needs both, and one of the two is not enough.
verdict allow demo g pg.prod read
verdict deny  demo g pg.prod change
if "$helper" edit-extract demo pg.prod >/dev/null 2>&1; then
    fail "editing pg.prod opened on a read allow alone"
fi
rm -rf "$gate_cache"
verdict allow demo g pg.prod read
verdict allow demo g pg.prod change
"$helper" edit-extract demo pg.prod | grep -q '^PG_PROD_PASS=' \
    || fail "editing pg.prod did not open with both allowed"
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
