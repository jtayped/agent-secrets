# migrations

one file per store format version, named `NNN-short-name.sh`, run in order by
`secret-update` when the store's recorded version is lower than the version the
installed code expects.

## the rules

1. **a migration never reads, rewrites or re-encrypts a scope.** scopes are
   your data. the tool's job during an upgrade is to leave them exactly as they
   were. anything that needs the plaintext is not a migration, it is a
   conversion, and it belongs behind an explicit command the person runs on
   purpose.
2. **a migration is idempotent.** running it twice must be the same as running
   it once. the runner records progress, but a half-finished run must be safe
   to repeat.
3. **a migration never touches `key/`.** losing the key loses everything, and
   no upgrade is worth that risk.

the runner takes a backup of `scopes/` and `index/` before it starts, and tells
you where it put it.

## available to a migration

- `AGENT_SECRETS_STORE` — the store directory, exported by the runner
- the installed `secret-*` commands, on `PATH`

exit non-zero to stop the upgrade. the runner will not record the new version,
so the migration runs again next time.
