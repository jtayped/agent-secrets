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

# ---------------------------------------------------------------------------
# a save is gated on what it changes, not on the group it was opened for.
#
# editing service.api, which nothing guards, could add `#@g pg_prod`. that
# group's PG_PROD_ prefix is longer than pg's PG_, so PG_PROD_PASS moved out of
# the marked pg and read with no dialog at all.
#
# taking protection away is asked every time and never answered from the
# cache. cases that would reach the dialog run the helper's own functions in a
# subshell with the approval channel and the dialog replaced, so none of them
# can open a real window on a desktop that runs the suite.
stubbed() {
    local channel="$1" answer="$2"
    shift 2
    # shellcheck disable=SC1090,SC2317
    (
        source "$helper" || true
        if [[ "$channel" == on ]]; then approval_channel_ok() { return 0; }
        else approval_channel_ok() { return 1; }
        fi
        ask_dialog() { printf '%s\n%s\n' "$1" "$2" > "$test_dir/dialog"; return "$answer"; }
        "$@"
    )
}
seed_capture() {
    "$helper" encrypt capture > "$AGENT_SECRETS_DIR/scopes/capture.env.gpg" <<'scope'
#@g service.api  test api credentials
SERVICE_API_TOKEN=api-value

#@sensitive
#@g pg  every postgres server
PG_PROD_PASS=prod-secret
scope
    secret-reindex capture >/dev/null
}
capture_edit=$'#@g service.api  test api credentials\nSERVICE_API_TOKEN=api-value\n#@g pg_prod  harmless looking\n'
capture_file="$AGENT_SECRETS_DIR/scopes/capture.env.gpg"
seed_capture

# the reported path, end to end: secret-edit with an editor that adds one line.
editor="$test_dir/add-pg-prod.sh"
printf '#!/bin/sh\nprintf "#@g pg_prod  harmless looking\\n" >> "$1"\n' > "$editor"
chmod +x "$editor"
verdict deny capture g pg change
before_sum="$(cksum < "$capture_file")"
rc=0
EDITOR="$editor" secret-edit capture service.api >/dev/null 2>"$test_dir/err" || rc=$?
[[ "$rc" -eq 77 ]] || fail "a group edit that takes PG_PROD_PASS out from under pg was not refused (exit $rc)"
[[ "$(cksum < "$capture_file")" == "$before_sum" ]] || fail "a refused capture still rewrote the scope"
grep -q 'denied' "$test_dir/err" || fail "the capture was refused, but not by the gate: $(head -2 "$test_dir/err")"
rm -rf "$gate_cache"

# an approval of some earlier change to pg is not an answer to this one.
verdict allow capture g pg change
rc=0
stubbed off 0 cmd_edit_merge capture service.api <<< "$capture_edit" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 69 ]] || fail "a cached change allow answered a loosening (exit $rc, wanted 69: it should have needed a dialog)"
rm -rf "$gate_cache"

# when it does reach the dialog, the dialog says what is being given up.
rm -f "$test_dir/dialog"
stubbed on 0 cmd_edit_merge capture service.api <<< "$capture_edit" >/dev/null 2>&1 \
    || fail "an allowed loosening was not written"
grep -q 'removes protection' "$test_dir/dialog" || fail "the loosening dialog did not say so in its title"
grep -q 'PG_PROD_PASS: no longer behind pg' "$test_dir/dialog" || fail "the dialog did not name the key and what it loses: $(cat "$test_dir/dialog")"
grep -q 'asked every time' "$test_dir/dialog" || fail "the dialog did not say a loosening is never remembered"
rm -rf "$gate_cache"

# a no is remembered against what it touched, so a retry loop meets the deny
# instead of a fresh dialog.
rc=0
stubbed on 1 cmd_edit_merge capture service.api <<< "$capture_edit" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 77 ]] || fail "a denied loosening did not exit 77 (exit $rc)"
rm -f "$test_dir/dialog"
rc=0
stubbed on 0 cmd_edit_merge capture service.api <<< "$capture_edit" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 77 ]] || fail "a retry straight after a denied loosening was not refused from the cache (exit $rc)"
[[ ! -e "$test_dir/dialog" ]] || fail "a retry straight after a denied loosening opened a dialog"
rm -rf "$gate_cache"

# removing the mark is a loosening too, even with the group's edit approved.
verdict allow capture g pg change
rc=0
stubbed off 0 cmd_edit_merge capture pg <<< $'#@g pg  every postgres server\nPG_PROD_PASS=prod-secret\n' >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 69 ]] || fail "unmarking pg went through without asking (exit $rc)"
rm -rf "$gate_cache"

# adding a mark only tightens, and asks nothing. a verdict cached for that
# name before it was marked was given to something else, and is dropped.
verdict allow capture g service.api read
rc=0
stubbed off 0 cmd_edit_merge capture service.api \
    <<< $'#@sensitive\n#@g service.api  test api credentials\nSERVICE_API_TOKEN=api-value\n' >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "marking service.api needed an approval (exit $rc)"
[[ ! -e "$(helper_call verdict_file "$gate_cache" capture g service.api read)" ]] \
    || fail "a verdict cached before service.api was marked survived the mark"
rm -rf "$gate_cache"

# a write is gated on the groups above the key, not on groups below it. this
# used to ask about every marked descendant of the destination as well.
"$helper" encrypt nested > "$AGENT_SECRETS_DIR/scopes/nested.env.gpg" <<'scope'
#@g pg  postgres, unguarded at this level
PG_HOST=h

#@sensitive
#@g pg.prod  production
PG_PROD_PASS=p
scope
secret-reindex nested >/dev/null
verdict deny nested g pg.prod change
printf 'port' | secret-set nested pg.PORT >/dev/null 2>&1 \
    || fail "writing into pg asked about its marked child pg.prod"
rm -rf "$gate_cache"

# ---------------------------------------------------------------------------
# integrity: nothing the caller did not name may disappear or change.
seed_capture
before="$(gpg --quiet --batch --pinentry-mode loopback --passphrase-file "$AGENT_SECRETS_DIR/key/.key" \
    --decrypt "$capture_file" 2>/dev/null)"
dropped="$(grep -v '^PG_PROD_PASS=' <<< "$before")"
rc=0
out="$(stubbed off 0 commit_policy capture "$before" "$dropped" "" "test" 2>&1)" || rc=$?
[[ "$rc" -ne 0 && "$out" == *"PG_PROD_PASS would be lost"* ]] || fail "a key dropped without being named was let through: $out"
changed="$(sed 's/^SERVICE_API_TOKEN=.*/SERVICE_API_TOKEN=other/' <<< "$before")"
rc=0
out="$(stubbed off 0 commit_policy capture "$before" "$changed" "" "test" 2>&1)" || rc=$?
[[ "$rc" -ne 0 && "$out" == *"value of SERVICE_API_TOKEN would change"* ]] || fail "a value changed without being named was let through: $out"
rc=0
stubbed off 0 commit_policy capture "$before" "$changed" $'W\tSERVICE_API_TOKEN' "test" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "a named write to an unguarded key was refused (exit $rc)"

# ---------------------------------------------------------------------------
# mutation test: without loosen detection, the capture above goes through.
#
# without this, the refusal could be coming from somewhere else entirely and
# the test would keep passing after the check that matters was deleted.
sabotaged="$test_dir/sabotaged-helper"
sed 's|printf "L\\t%s\\tno longer behind %s\\n", k2, substr(id, 3); lost\[id\] = 1|sabotaged = 1|' "$helper" > "$sabotaged"
chmod 755 "$sabotaged"
if cmp -s "$helper" "$sabotaged"; then
    fail "the mutation test did not modify the helper; its sed pattern needs updating"
else
    seed_capture
    verdict deny capture g pg change
    if ! "$sabotaged" edit-merge capture service.api <<< "$capture_edit" >/dev/null 2>&1; then
        fail "with loosen detection removed the capture was still refused, so the capture test is not testing it"
    fi
    rm -rf "$gate_cache"
fi

if [[ "$failures" -ne 0 ]]; then
    echo "$failures gate check(s) failed" >&2
    exit 1
fi
echo "gate checks passed"
