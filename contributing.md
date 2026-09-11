# contributing

keep the repository free of encrypted scopes, keys, indexes from real stores, ssh keys, and rclone configuration.

run both test suites before opening a pull request:

~~~bash
./tests/smoke.sh
./tests/upgrade.sh
~~~

`upgrade.sh` is the one that guards the promise in docs/updating.md: an upgrade
replaces code and never touches a stored secret. if a change makes it fail, the
change is wrong, not the test.

run the root installer only on a disposable test account or your own machine. it writes to /usr/local/libexec and /etc/sudoers.d.

keep command output and prose lowercase. uppercase remains where an external format requires it, including .env variable names, systemd directive names, and environment variable names.

main is protected. push a branch and open a pull request; direct pushes are
rejected for everyone, and ci has to pass before a merge.

if a change alters the scope format or approval behavior, update docs/format.md, docs/security.md, and skills/secrets/SKILL.md in the same pull request.

if a change requires an existing store to be different on disk, it needs a
numbered script in migrations/ and a bump to AGENT_SECRETS_STORE_FORMAT in
bin/secret-common.sh. read migrations/readme.md first: a migration may not read,
rewrite or re-encrypt a scope.

if a change alters what the helper accepts from the wrappers, bump
HELPER_PROTOCOL in lib/agent-secrets-helper and AGENT_SECRETS_MIN_HELPER_PROTOCOL
in bin/secret-common.sh together, so an install with a stale privileged helper
gets a clear message instead of undefined behaviour.
