#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export AGENT_SECRETS_DIR="$test_dir/.secrets"
export AGENT_SECRETS_HELPER_INSTALLED="$test_dir/no-installed-helper"
export AGENT_SECRETS_HELPER_LOCAL="$repo_dir/lib/agent-secrets-helper"
export PATH="$repo_dir/bin:$PATH"

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

# the whole scope stays valid: it is the only thing that reaches ungrouped keys.
secret-run demo -- true

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
