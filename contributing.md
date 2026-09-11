# contributing

keep the repository free of encrypted scopes, keys, indexes from real stores, ssh keys, and rclone configuration.

run the test suite before opening a pull request:

~~~bash
for t in tests/*.sh; do "$t" || break; done
~~~

[tests/readme.md](tests/readme.md) says what each file guards and why. the
short version: `key.sh` and `integrity.sh` cover the paths where a bug loses
secrets rather than returning a wrong answer, and `upgrade.sh` guards the
promise in docs/updating.md that an upgrade replaces code and never touches a
stored secret. a change that makes one of those fail is wrong until proven
otherwise; do not adjust the test to match the change.

never pass a multi-line value to `awk -v`. the awk that ships with macos
rejects a newline inside a `-v` assignment, and if the awk runs inside a
process substitution nobody sees the exit status, so the whole pipeline just
produces nothing. that is how `secret-edit <scope> <group>` came to delete every
other group on every mac. pass lists on stdin or as a file; keep `-v` for single
values.

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
