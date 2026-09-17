#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export AGENT_SECRETS_DIR="$test_dir/.secrets"
export AGENT_SECRETS_HELPER_INSTALLED="$test_dir/no-installed-helper"
export AGENT_SECRETS_HELPER_LOCAL="$repo_dir/lib/agent-secrets-helper"
export PATH="$repo_dir/bin:$PATH"
# the gate's verdict cache follows XDG_RUNTIME_DIR for a helper running as the
# user. pointing it inside the test directory keeps the suite off the real
# one, and gives the tests below somewhere to pre-seed a verdict.
export XDG_RUNTIME_DIR="$test_dir/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
gate_cache="$XDG_RUNTIME_DIR/agent-secrets-gate"

# A cached verdict is answered without opening a dialog, on either platform.
# That is what lets the suite assert which operations reach the gate and which
# skip it, with no session anywhere and nothing for anyone to click.
deny_cached() {
    mkdir -p "$gate_cache"
    chmod 700 "$gate_cache"
    printf 'deny 9999999999\n' > "$gate_cache/${1}__${2//./_}"
}

secret-init >/dev/null

scope_file="$AGENT_SECRETS_DIR/scopes/demo.env.gpg"
agent_secrets_helper="$repo_dir/lib/agent-secrets-helper"
"$agent_secrets_helper" encrypt demo > "$scope_file" <<'scope'
#@g service.api  test api credentials
#@d test token
SERVICE_API_TOKEN=first-value

#@a server=demo
#@a kind=endpoint
#@g pg.demo  test database endpoint
PG_DEMO_HOST=db.test

#@a kind=role
#@a mode=ro
#@g pg.demo.ro  demo_ro: read-only, default choice for reads.
PG_DEMO_RO_USER=demo_ro
PG_DEMO_RO_PASS=ro-value
scope
secret-reindex demo >/dev/null

secret-list demo --keys | grep -qx 'SERVICE_API_TOKEN'
secret-list demo --keys | grep -qx 'PG_DEMO_HOST'
tree="$(secret-list demo --tree)"
[[ "$tree" == *"service.api"* ]]
[[ "$tree" == *"pg.demo"* ]]

# the level view is an ls: one level, never the whole subtree.
top="$(secret-list demo)"
[[ "$top" == *"service/"* ]]
[[ "$top" == *"pg/"* ]]
[[ "$top" != *"service.api"* ]]

level="$(secret-list demo service)"
[[ "$level" == *"demo:service"* ]]
[[ "$level" == *"api/"* ]]

leaf="$(secret-list demo service.api)"
[[ "$leaf" == *"TOKEN"* ]]
[[ "$leaf" != *"PG_DEMO_HOST"* ]]

# an unknown group names its siblings rather than just failing.
if missing="$(secret-list demo service.nope 2>&1)"; then
    echo "expected secret-list to reject an unknown group" >&2
    exit 1
fi
[[ "$missing" == *"at that level:"* ]]

# --tree scoped to a group stays inside it.
subtree="$(secret-list demo service --tree)"
[[ "$subtree" == *"service.api"* ]]
[[ "$subtree" != *"pg.demo"* ]]

result="$(secret-run demo service.api -- bash -c 'printf "%s" "$SERVICE_API_TOKEN"')"
[[ "$result" == "first-value" ]]

# a group path that parses but names nothing has to be an error, not an empty
# environment. secret-list has always rejected one; secret-run used to hand the
# command no values and exit 0, so the failure surfaced wherever the command
# happened to need the credential and looked nothing like a wrong group name.
for bad in nope service.nope pg.demo.nope; do
    if out="$(secret-run demo "$bad" -- true 2>&1)"; then
        echo "expected secret-run to reject unknown group '$bad'" >&2
        exit 1
    fi
    [[ "$out" == *"no group '$bad'"* ]] || {
        echo "secret-run rejected '$bad' without naming it: $out" >&2
        exit 1
    }
done

# this doubles as the regression test for secret-approve's exit status: it used
# to read $? after a bare `if`, which is 0 whenever the condition failed, so
# every failure including a denial was reported to the caller as success.
if out="$(secret-approve demo --motive "test." service.nope 2>&1)"; then
    echo "expected secret-approve to reject an unknown group" >&2
    exit 1
fi
[[ "$out" == *"no group 'service.nope'"* ]]

# an ancestor nobody declared still selects its descendants, because render()
# accepts it. tightening the check to declared paths only would break this.
result="$(secret-run demo service -- bash -c 'printf "%s" "$SERVICE_API_TOKEN"')"
[[ "$result" == "first-value" ]]

# two groups that are not one subtree. this is the shape the tool had no answer
# for: reaching both used to mean --all-groups, which hands over the whole
# scope, and nesting one run inside another does not work at all -- the outer
# environment is dropped when the hardened helper steps down to the calling
# account.
result="$(secret-run demo service.api pg.demo.ro -- bash -c 'printf "%s|%s" "$SERVICE_API_TOKEN" "$PG_DEMO_RO_USER"')"
[[ "$result" == "first-value|demo_ro" ]]

# and only those two. naming several narrow groups must not widen to a parent.
result="$(secret-run demo service.api pg.demo.ro -- bash -c 'printf "%s" "${PG_DEMO_HOST-unset}"')"
[[ "$result" == "unset" ]]

# overlapping paths are not an error. a parent and one of its children select
# the same group twice, and each value still arrives once.
result="$(secret-run demo pg.demo pg.demo.ro -- bash -c 'printf "%s|%s" "$PG_DEMO_HOST" "$PG_DEMO_RO_USER"')"
[[ "$result" == "db.test|demo_ro" ]]

# every named group is checked before the gate, so a typo in the second one is
# found before anyone is asked to approve the first.
if out="$(secret-run demo service.api service.nope -- true 2>&1)"; then
    echo "expected secret-run to reject an unknown group named second" >&2
    exit 1
fi
[[ "$out" == *"no group 'service.nope'"* ]]

# --all-groups already is the whole scope. combining it with a group name means
# two different things at once, so say that rather than quietly picking one.
if out="$(secret-run demo service.api --all-groups -- true 2>&1)"; then
    echo "expected secret-run to reject --all-groups next to a group name" >&2
    exit 1
fi
[[ "$out" == *"--all-groups"* ]]

if out="$(secret-run demo --all-groups service.api -- true 2>&1)"; then
    echo "expected secret-run to reject a group name after --all-groups" >&2
    exit 1
fi
[[ "$out" == *"--all-groups"* ]]

# a run naming no group is refused, and the refusal has to be useful: it names
# the whole-scope form rather than just rejecting, and points at the ungated
# read-only role, which is what the caller almost always actually wanted.
#
# this needs a scope with a sensitive group to count, and the refusal happens
# before the gate, so no dialog is ever reached. it lives in its own scope
# because `demo` is what the --all-groups case runs, and that one does gate:
# ci has no session to answer a dialog with.
"$agent_secrets_helper" encrypt gated > "$AGENT_SECRETS_DIR/scopes/gated.env.gpg" <<'scope'
#@a kind=role
#@a mode=ro
#@g pg.one.ro  one_ro: read-only, default choice for reads.
PG_ONE_RO_USER=one_ro

#@sensitive
#@a kind=role
#@a mode=rw
#@g pg.one.rw  one_rw: read-write.
PG_ONE_RW_USER=one_rw
scope
secret-reindex gated >/dev/null

if out="$(secret-run gated -- true 2>&1)"; then
    echo "expected secret-run to refuse a run that names no group" >&2
    exit 1
fi
[[ "$out" == *"names no group"* ]]
[[ "$out" == *"--all-groups"* ]]
[[ "$out" == *"pg.one.ro"* ]]
[[ "$out" == *"default choice for reads"* ]]
# the gated group is counted, and a sensitive group is never offered as a hint.
[[ "$out" == *"clear its sensitive group"* ]]
[[ "$out" != *"pg.one.rw"* ]]

# the count has to be what the dialog would list, not every group carrying an
# effective mark. sensitivity inherits, and the gate suppresses a child whose
# parent is already marked because one prompt covers both -- so counting marks
# rather than prompts promises more dialogs than could ever open.
"$agent_secrets_helper" encrypt inherited > "$AGENT_SECRETS_DIR/scopes/inherited.env.gpg" <<'scope'
#@sensitive
#@g srv  a whole server, marked once.
SRV_HOST=h

#@g srv.ro  inherits the mark from srv.
SRV_RO_USER=u

#@g srv.rw  also inherits it.
SRV_RW_USER=u
scope
secret-reindex inherited >/dev/null
[[ "$(secret-list inherited --tree | grep -c 'sensitive')" == "3" ]]
out="$(secret-run inherited -- true 2>&1 || true)"
[[ "$out" == *"clear its sensitive group"* ]] || {
    echo "expected one prompt to be counted, not three marks: $out" >&2
    exit 1
}

# a write is not a read: the value goes in, and no plaintext comes back out. so
# the gate follows the destination rather than the whole scope. writing into an
# ungated group must not consult the sensitive one at all -- before this was
# narrowed, one added key cost an approval for every sensitive group in the
# scope.
deny_cached gated pg.one.rw
printf 'ro-pass' | secret-set gated pg.one.ro.PASS --desc "one_ro password" >/dev/null
secret-list gated --keys | grep -qx 'PG_ONE_RO_PASS'

# writing into the sensitive group itself still does consult it, and a refused
# write stores nothing.
if printf 'rw-pass' | secret-set gated pg.one.rw.PASS --desc "one_rw password" >/dev/null 2>&1; then
    echo "expected the write gate to fire for a sensitive destination" >&2
    exit 1
fi
if secret-list gated --keys | grep -qx 'PG_ONE_RW_PASS'; then
    echo "a refused write must not store anything" >&2
    exit 1
fi

# a key landing outside every group is gated on its own name, which is the
# identity a key marked on its own carries. a new one matches nothing, so it
# asks nothing.
printf 'loose' | secret-set gated LOOSE_KEY --desc "outside every group" >/dev/null
secret-list gated --keys | grep -qx 'LOOSE_KEY'
rm -rf "$gate_cache"

# a run naming several groups is gated on exactly those groups. the ungated one
# still costs nothing while the sensitive one stands denied, and naming both is
# refused by the one carrying the mark -- the union of what was asked for, not
# the whole scope and not just the first path.
deny_cached gated pg.one.rw
secret-run gated pg.one.ro -- true
if out="$(secret-run gated pg.one.ro pg.one.rw -- true 2>&1)"; then
    echo "expected a sensitive group in the set to refuse the whole run" >&2
    exit 1
fi
[[ "$out" == *"denied"* ]]
rm -rf "$gate_cache"

# `ask` refuses an existing key before it opens a dialog, not after. this is the
# one branch of the verb the suite can reach: everything past it waits on
# someone typing into a prompt, and ci has nobody to do that.
if out="$(secret-ask gated pg.one.ro.PASS --desc "already there" 2>&1)"; then
    echo "expected secret-ask to refuse an existing key" >&2
    exit 1
fi
[[ "$out" == *"already exists"* ]]
[[ "$out" == *"--force"* ]]

# and it refuses a destination that could never work before asking too.
if out="$(secret-ask gated 'not a path' 2>&1)"; then
    echo "expected secret-ask to refuse a malformed path" >&2
    exit 1
fi

# several destinations in one ask. every refusal still happens before the
# dialog, and a refusal anywhere in the set stores none of it -- the values are
# spliced together and encrypted once for exactly that reason.
if out="$(secret-ask gated pg.one.ro.USER2 --desc "one" pg.one.ro.USER2 --desc "again" 2>&1)"; then
    echo "expected secret-ask to refuse the same key twice in one ask" >&2
    exit 1
fi
[[ "$out" == *"named twice"* ]]

if out="$(secret-ask gated pg.one.ro.NEWA --desc "new" pg.one.ro.PASS --desc "exists" 2>&1)"; then
    echo "expected secret-ask to refuse when one of several keys exists" >&2
    exit 1
fi
[[ "$out" == *"already exists"* ]]
if secret-list gated --keys | grep -qx 'PG_ONE_RO_NEWA'; then
    echo "a refused multi-key ask must store none of it" >&2
    exit 1
fi

# the gate runs before the dialog, so a refused write is refused before anyone
# is asked to type a credential that was never going to be stored.
deny_cached gated pg.one.rw
if out="$(secret-ask gated pg.one.rw.NEWPASS --desc "new" 2>&1)"; then
    echo "expected secret-ask to refuse a gated destination" >&2
    exit 1
fi
[[ "$out" == *"denied"* ]]
if secret-list gated --keys | grep -qx 'PG_ONE_RW_NEWPASS'; then
    echo "a refused ask must not store anything" >&2
    exit 1
fi

# one gate for the whole set, and a gated destination anywhere in it refuses
# the lot before the dialog.
if out="$(secret-ask gated pg.one.ro.NEWB --desc "ungated" pg.one.rw.NEWC --desc "gated" 2>&1)"; then
    echo "expected one gated destination to refuse the whole ask" >&2
    exit 1
fi
if secret-list gated --keys | grep -qx 'PG_ONE_RO_NEWB'; then
    echo "a gated destination must refuse the whole set, not part of it" >&2
    exit 1
fi
rm -rf "$gate_cache"

# --all-groups still reaches ungrouped keys, which is the whole point of keeping
# it. demo carries no sensitive mark, so this clears no gate and needs no session.
#
# that last part is load-bearing and easy to undo by accident: adding a
# #@sensitive group to the demo fixture makes the next line ask for a dialog,
# which ci has no session to answer, and the failure it produces (exit 69)
# names the gate rather than the fixture. so check the fixture, not the symptom.
if [[ "$(secret-list demo --tree | grep -c '\[sensitive\]')" != "0" ]]; then
    echo "the demo fixture must carry no sensitive group: --all-groups runs against it" >&2
    exit 1
fi
secret-run demo --all-groups -- true

# an ungated read-only role costs no dialog, which is why the hint points there.
result="$(secret-run demo pg.demo.ro -- bash -c 'printf "%s" "$PG_DEMO_RO_USER"')"
[[ "$result" == "demo_ro" ]]

printf 'second-value' | secret-set demo service.api.second --desc "test second value" >/dev/null
secret-list demo --keys | grep -qx 'SERVICE_API_SECOND'
! grep -qF 'first-value' "$AGENT_SECRETS_DIR/index/demo.toc"
! grep -qF 'second-value' "$AGENT_SECRETS_DIR/index/demo.toc"

pg="$(pg-hosts --scope demo)"
[[ "$pg" == *"demo"* ]]
[[ "$pg" == *"pg.demo"* ]]

# the helper has to keep running on the bash 3.2 that macos ships at the only
# bash path root owns, so bash 4 syntax in that file is a portability bug even
# where it works.
if grep -vE '^[[:space:]]*#' "$agent_secrets_helper" \
     | grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)'; then
    echo "helper uses bash 4 syntax; it must stay bash 3.2 clean" >&2
    exit 1
fi

secret-doctor > "$test_dir/doctor.out" || true
grep -q 'agent-secrets doctor' "$test_dir/doctor.out"
grep -q 'indexed' "$test_dir/doctor.out"

echo "smoke test passed"
