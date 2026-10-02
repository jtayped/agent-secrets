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
# a test that reaches an approval dialog fails, rather than drawing one on the
# desktop of whoever runs the suite.
export AGENT_SECRETS_NO_DIALOG=1
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
        ask_dialog() { printf '%s\n' "$@" > "$test_dir/dialog"; return "$answer"; }
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
grep -q 'PG_PROD_PASS: no longer behind pg, and behind nothing' "$test_dir/dialog" || fail "the dialog did not name the key and what it loses: $(cat "$test_dir/dialog")"
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
# approval lifetime.
#
# an allow line is `allow <expires> <hard-expiry> <window>`. using it moves
# <expires> to now + <window>, never past <hard-expiry>, which is fixed at the
# yes. these write lines with chosen times and watch what the gate does to them.
vfile() { helper_call verdict_file "$gate_cache" "$1" "$2" "$3" "$4"; }
allow_line() {
    mkdir -p "$gate_cache"
    chmod 700 "$gate_cache"
    printf 'allow %s %s %s\n' "$2" "$3" "$4" > "$1"
}
field() { awk -v n="$2" '{ print $n }' "$1"; }
f="$(vfile demo g pg.prod read)"

now=$(date +%s)
allow_line "$f" $((now + 100)) $((now + 43200)) 900
secret-run demo pg.prod -- true || fail "an approval with time left did not open"
(( $(field "$f" 2) >= now + 890 )) || fail "using an approval did not push its expiry out by its window: $(cat "$f")"
[[ "$(field "$f" 3)" == $((now + 43200)) ]] || fail "using an approval moved its hard expiry: $(cat "$f")"

now=$(date +%s)
allow_line "$f" $((now + 100)) $((now + 200)) 900
secret-run demo pg.prod -- true || fail "an approval inside its hard expiry did not open"
[[ "$(field "$f" 2)" == "$(field "$f" 3)" ]] \
    || fail "using an approval 100s from its hard expiry should leave it ending exactly there: $(cat "$f")"

now=$(date +%s)
allow_line "$f" $((now - 1)) $((now + 43200)) 900
[[ -z "$(helper_call cached_verdict demo g pg.prod "$gate_cache" read)" ]] || fail "an idle approval outlived its window"
allow_line "$f" $((now + 100)) $((now - 1)) 900
[[ -z "$(helper_call cached_verdict demo g pg.prod "$gate_cache" read)" ]] || fail "an approval outlived its hard expiry"
rm -rf "$gate_cache"

# more than twelve hours is refused before anything else, by the wrapper's
# reading of the duration and by the helper's own range check.
verdict deny demo g pg.prod read
out="$(secret-run demo pg.prod --for 13h -- true 2>&1)" && fail "--for 13h was accepted"
[[ "$out" == *"most an approval can last is 12 hours"* ]] || fail "--for 13h was refused, but not for its length: $out"
out="$("$helper" run demo pg.prod --for 50000 -- true 2>&1)" && fail "the helper took a 50000 second window"
[[ "$out" == *"12 hours"* ]] || fail "the helper refused 50000 seconds, but not for its length: $out"
out="$(secret-run demo pg.prod --for 2x -- true 2>&1)" && fail "--for 2x was accepted"
[[ "$out" == *"takes a duration"* ]] || fail "--for 2x was refused, but not as a bad duration: $out"
rm -rf "$gate_cache"

# asking for longer than what was approved asks again rather than silently
# getting the shorter window. asking for no longer than that does not.
now=$(date +%s)
allow_line "$f" $((now + 500)) $((now + 43200)) 900
rc=0
stubbed off 0 cmd_run demo pg.prod --for 7200 -- true >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 69 ]] || fail "a 2 hour request was answered by a 15 minute approval (exit $rc)"
rc=0
stubbed off 0 cmd_run demo pg.prod --for 600 -- true >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "a 10 minute request was not answered by a 15 minute approval (exit $rc)"
rm -rf "$gate_cache"

# a request for longer than usual offers the usual window as a second allow.
rm -f "$test_dir/dialog"
stubbed on 0 cmd_run demo pg.prod --for 7200 -- true >/dev/null 2>&1 || fail "an allowed 2 hour request did not run"
grep -qx 'allow 2 hours' "$test_dir/dialog" || fail "the dialog did not offer the requested window as its allow button"
grep -qx 'allow 15 minutes' "$test_dir/dialog" || fail "the dialog did not offer the usual window as a second button"
grep -q 'for 2 hours after their last use, and at most 12 hours in all' "$test_dir/dialog" \
    || fail "the dialog did not state the window and the ceiling: $(cat "$test_dir/dialog")"
[[ "$(field "$f" 4)" == 7200 ]] || fail "allowing 2 hours did not record a 2 hour window: $(cat "$f")"
rm -rf "$gate_cache"
stubbed on 4 cmd_run demo pg.prod --for 7200 -- true >/dev/null 2>&1 || fail "the shorter allow did not run"
[[ "$(field "$f" 4)" == 900 ]] || fail "the shorter allow did not record the usual window: $(cat "$f")"
rm -rf "$gate_cache"

# secret-approve takes --for too, and is answered by an approval at least that long.
now=$(date +%s)
allow_line "$f" $((now + 500)) $((now + 43200)) 7200
secret-approve demo --motive "lifetime check" --for 2h pg.prod || fail "secret-approve --for 2h was not answered by a 2 hour approval"
rm -rf "$gate_cache"

# ---------------------------------------------------------------------------
# locking a group again before its approval runs out.
"$helper" encrypt relock > "$AGENT_SECRETS_DIR/scopes/relock.env.gpg" <<'scope'
#@sensitive
#@g srv  a whole server
SRV_HOST=h

#@g srv.ro  read-only, guarded by srv
SRV_RO_USER=u

#@sensitive
#@g other  something else
OTHER_TOKEN=t

#@sensitive
SOLO_KEY=s
scope
secret-reindex relock >/dev/null

# revoking srv.ro has to clear the approval that actually opens it, which is
# srv's. leaving srv approved would leave srv.ro exactly as readable as before.
verdict allow relock g srv read
verdict allow relock g srv change
verdict allow relock g other read
verdict deny  relock k SOLO_KEY read
out="$(secret-approve relock --revoke srv.ro)" || fail "secret-approve --revoke srv.ro failed"
[[ ! -e "$(vfile relock g srv read)" ]] || fail "revoking srv.ro left srv's read approval standing"
[[ ! -e "$(vfile relock g srv change)" ]] || fail "revoking srv.ro left srv's change approval standing"
[[ "$out" == *"locked srv (read)"* ]] || fail "the revoke did not say what it locked: $out"
[[ -e "$(vfile relock g other read)" ]] || fail "revoking srv.ro also locked an unrelated group"

# the whole scope, and never a deny: the owner's no outlives any revoke.
out="$(secret-approve relock --revoke)" || fail "secret-approve --revoke on a whole scope failed"
[[ ! -e "$(vfile relock g other read)" ]] || fail "a whole-scope revoke left an approval standing"
[[ "$out" == *"locked other (read)"* ]] || fail "the whole-scope revoke did not name what it locked: $out"
[[ "$(field "$(vfile relock k SOLO_KEY read)" 1)" == deny ]] || fail "a revoke cleared the owner's deny"
verdict allow relock k SOLO_KEY change
out="$(secret-approve relock --revoke)"
[[ "$out" == *"locked SOLO_KEY (change)"* ]] || fail "a key's approval was not named by its key: $out"
rm -rf "$gate_cache"

# ---------------------------------------------------------------------------
# secret-group and secret-meta ask what the change policy says, and only that.
"$helper" encrypt meta > "$AGENT_SECRETS_DIR/scopes/meta.env.gpg" <<'scope'
#@g open  nothing guards this
OPEN_TOKEN=o

#@sensitive
#@g vault  guarded
VAULT_PASS=v
VAULT_CHILD_TOKEN=c
scope
secret-reindex meta >/dev/null
meta_file="$AGENT_SECRETS_DIR/scopes/meta.env.gpg"

# adding a mark tightens, and asks nothing. a read verdict cached under the
# name before the mark existed is dropped with it.
verdict allow meta g open read
secret-meta meta open --sensitive >/dev/null || fail "marking a group needed an approval"
secret-list meta --tree | grep -q 'open.*\[sensitive\]' || fail "the mark did not land"
[[ ! -e "$(vfile meta g open read)" ]] || fail "a read verdict from before the mark survived it"
rm -rf "$gate_cache"

# a description is what the approval dialog shows, so changing one on a
# guarded group asks as a change.
verdict deny meta g vault change
before_sum="$(cksum < "$meta_file")"
if secret-meta meta vault --desc "harmless, really" >/dev/null 2>&1; then
    fail "the description of a marked group changed without its approval"
fi
[[ "$(cksum < "$meta_file")" == "$before_sum" ]] || fail "a refused description change still wrote the scope"
rm -rf "$gate_cache"
verdict allow meta g vault change
secret-meta meta vault --desc "the vault, renamed" >/dev/null || fail "an approved description change was refused"
rm -rf "$gate_cache"

# removing a mark, or making its approvals last longer, asks every time.
verdict allow meta g vault change
rc=0
stubbed off 0 cmd_meta meta vault 0 unmark >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 69 ]] || fail "--not-sensitive went through on a cached change approval (exit $rc)"
rc=0
stubbed off 0 cmd_meta meta vault 0 ttl 7200 >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 69 ]] || fail "a longer ttl went through on a cached change approval (exit $rc)"
rc=0
stubbed off 0 cmd_meta meta vault 0 ttl 300 >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "a shorter ttl needed a dialog (exit $rc)"
rm -rf "$gate_cache"

# a group mark that takes over from a key's own mark is a loosening too: the
# dialog would show the group's description instead of the key's, and the
# group's could have been written by whatever marked it.
"$helper" encrypt solo > "$AGENT_SECRETS_DIR/scopes/solo.env.gpg" <<'scope'
#@g root  root credentials
#@sensitive
#@d the production root password
ROOT_PASS=r
scope
secret-reindex solo >/dev/null
out="$(secret-meta solo root --sensitive --dry-run)"
[[ "$out" == *"asks every time: ROOT_PASS no longer behind ROOT_PASS, only behind root"* ]] \
    || fail "a group mark taking over a key's own mark was not asked about: $out"

# the dry run names the prompt it would open, and writes nothing.
before_sum="$(cksum < "$meta_file")"
out="$(secret-meta meta vault --not-sensitive --dry-run)"
[[ "$out" == *"asks every time: VAULT_PASS no longer behind vault, and behind nothing"* ]] || fail "the dry run did not name the loosening: $out"
[[ "$(cksum < "$meta_file")" == "$before_sum" ]] || fail "a dry run wrote the scope"

# a group declared under a guarded one asks about that one.
verdict deny meta g vault change
if secret-group meta vault.child --desc "under the vault" --take >/dev/null 2>&1; then
    fail "a group was declared under vault without vault's approval"
fi
rm -rf "$gate_cache"

# and one that takes a key out from under a mark asks every time, --take or not.
verdict deny meta g vault change
if secret-group meta vault_child --desc "next to the vault" --take >/dev/null 2>&1; then
    fail "a group took VAULT_CHILD_TOKEN out from under vault without asking"
fi
grep -q '^VAULT_CHILD_TOKEN=' <<< "$(gpg --quiet --batch --pinentry-mode loopback \
    --passphrase-file "$AGENT_SECRETS_DIR/key/.key" --decrypt "$meta_file" 2>/dev/null)" \
    || fail "a refused group declaration lost a key"
rm -rf "$gate_cache"

# ---------------------------------------------------------------------------
# moving and removing ask what the change policy says.
seed_move() {
    "$helper" encrypt moves > "$AGENT_SECRETS_DIR/scopes/moves.env.gpg" <<'scope'
#@g plain  nothing guards this
PLAIN_TOKEN=p

#@sensitive
#@g vault  the production vault
VAULT_PASS=v
VAULT_USER=u

#@sensitive
#@d marked on its own
SOLO_KEY=s
scope
    secret-reindex moves >/dev/null
}
seed_move
moves_file="$AGENT_SECRETS_DIR/scopes/moves.env.gpg"
moves_plain() {
    gpg --quiet --batch --pinentry-mode loopback --passphrase-file "$AGENT_SECRETS_DIR/key/.key" \
        --decrypt "$moves_file" 2>/dev/null
}

# renaming a marked group keeps its keys behind the same mark under the new
# name, so it is a change to vault and not a loosening. an approval cached
# under the new name before it existed was given to something else.
verdict allow moves g vault change
verdict allow moves g safe read
secret-mv moves vault safe >/dev/null 2>&1 || fail "renaming a marked group was refused with its change approved"
secret-list moves --tree | grep -q 'safe \[sensitive\].*the production vault' || fail "the renamed group lost its mark or description"
[[ ! -e "$(vfile moves g safe read)" ]] || fail "a read verdict cached under the new name survived the rename"
rm -rf "$gate_cache"

# a key moving out from under a mark, or a copy of it that nothing guards, asks
# every time.
seed_move
verdict allow moves g vault change
before_sum="$(cksum < "$moves_file")"
rc=0; secret-mv moves VAULT_PASS plain.PASS >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 69 ]] || fail "moving VAULT_PASS out of vault did not need a dialog (exit $rc)"
rc=0; secret-mv moves VAULT_PASS plain.PASS --copy >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 69 ]] || fail "copying VAULT_PASS into plain did not need a dialog (exit $rc)"
[[ "$(cksum < "$moves_file")" == "$before_sum" ]] || fail "a refused move or copy still wrote the scope"
rm -rf "$gate_cache"

# a copy of a whole marked group carries its mark, under a name with no
# approvals yet, so it asks nothing.
secret-mv moves vault vault_copy --copy >/dev/null 2>&1 || fail "copying a marked group with its mark needed an approval"
secret-list moves --tree | grep -q 'vault_copy \[sensitive\]' || fail "the copy of vault is not marked"
rm -rf "$gate_cache"

# a key marked on its own takes its mark to its new name.
seed_move
verdict allow moves k SOLO_KEY change
secret-mv moves SOLO_KEY plain.SOLO >/dev/null 2>&1 || fail "a key marked on its own could not move with its change approved"
grep -q $'^K\tPLAIN_SOLO\tplain\tSOLO\t1\t1\t' "$AGENT_SECRETS_DIR/index/moves.toc" || fail "the moved key lost its own mark"
rm -rf "$gate_cache"

# removing a key a mark guards is a change to that group.
seed_move
verdict deny moves g vault change
secret-rm moves VAULT_USER >/dev/null 2>&1 && fail "VAULT_USER was removed without vault's approval"
grep -q '^VAULT_USER=' <<< "$(moves_plain)" || fail "a refused removal still removed VAULT_USER"
rm -rf "$gate_cache"
verdict allow moves g vault change
secret-rm moves VAULT_USER >/dev/null 2>&1 || fail "an approved removal was refused"
rm -rf "$gate_cache"

# removing a marked group's declaration leaves its keys behind less.
verdict allow moves g vault change
rc=0; secret-rm moves vault >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 69 ]] || fail "removing the vault declaration did not ask about its keys (exit $rc)"
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
sed 's|printf "L\\t%s\\tno longer behind %s%s\\n", k2, substr(id, 3), behind(A); lost\[id\] = 1|sabotaged = 1|' "$helper" > "$sabotaged"
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
