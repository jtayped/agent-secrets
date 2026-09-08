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

secret-list demo | rg -qx 'SERVICE_API_TOKEN'
secret-list demo | rg -qx 'PG_DEMO_HOST'
tree="$(secret-list demo --tree)"
[[ "$tree" == *"service.api"* ]]
[[ "$tree" == *"pg.demo"* ]]

result="$(secret-run demo service.api -- bash -c 'printf "%s" "$SERVICE_API_TOKEN"')"
[[ "$result" == "first-value" ]]

printf 'second-value' | secret-set demo service.api.second --desc "test second value" >/dev/null
secret-list demo | rg -qx 'SERVICE_API_SECOND'
! rg -F 'first-value' "$AGENT_SECRETS_DIR/index/demo.toc"
! rg -F 'second-value' "$AGENT_SECRETS_DIR/index/demo.toc"

pg="$(pg-hosts --scope demo)"
[[ "$pg" == *"demo"* ]]
[[ "$pg" == *"pg.demo"* ]]

echo "smoke test passed"
