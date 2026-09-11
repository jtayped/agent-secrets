#!/usr/bin/env bash
# store format 1: the first format that records its own version.
#
# every store created before secret-update existed is, by definition, at
# version 0. this migration adopts such a store: it checks the layout is what
# version 1 expects, rebuilds the display indexes, and records the version.
#
# it does not read, rewrite or re-encrypt a single scope. that is the rule for
# every migration in this directory, and the one worth being suspicious about
# when you add the next one.
set -euo pipefail

# the runner exports these.
: "${AGENT_SECRETS_STORE:?}"

echo "  checking the store layout"
for dir in scopes index key; do
    if [[ ! -d "$AGENT_SECRETS_STORE/$dir" ]]; then
        echo "  creating missing $dir/"
        mkdir -p "$AGENT_SECRETS_STORE/$dir"
        chmod 700 "$AGENT_SECRETS_STORE/$dir"
    fi
done

# indexes are a display cache with a format of their own, so rebuilding them is
# the one thing a migration can always safely do.
shopt -s nullglob
scopes=("$AGENT_SECRETS_STORE"/scopes/*.env.gpg)
shopt -u nullglob
if [[ ${#scopes[@]} -eq 0 ]]; then
    echo "  no scopes to index"
else
    echo "  rebuilding ${#scopes[@]} index file(s)"
    secret-reindex >/dev/null
fi
