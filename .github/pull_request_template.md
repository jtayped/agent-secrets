## what and why

<!-- what changes, and what problem it solves. -->

## checks

- [ ] `./tests/smoke.sh` passes
- [ ] `./tests/upgrade.sh` passes
- [ ] output and prose are lowercase, except where an external format requires otherwise

## does this touch the privileged half?

`lib/agent-secrets-helper`, `install-root.sh`, the sudoers rule, or the approval gate.

- [ ] no
- [ ] yes — and i have said below what a caller could do with the change that it could not do before

## does this change what is on disk?

- [ ] no
- [ ] yes — there is a numbered script in `migrations/`, `AGENT_SECRETS_STORE_FORMAT` is bumped, and the migration reads no plaintext

## does this change the wrapper/helper contract?

- [ ] no
- [ ] yes — `HELPER_PROTOCOL` and `AGENT_SECRETS_MIN_HELPER_PROTOCOL` are bumped together

## docs

- [ ] not needed
- [ ] `docs/format.md`, `docs/security.md`, `docs/compatibility.md`, `docs/updating.md` or `skills/secrets/SKILL.md` updated as required
