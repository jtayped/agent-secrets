# updating

the guarantee first, because it is the only part that really matters:

> **an upgrade replaces code. it does not read, rewrite, re-encrypt or delete a
> single stored secret.**

`install.sh` writes to `~/.local/bin` and `~/.local/libexec` and nowhere else.
the one thing it runs that goes near the store is `secret-init`, which creates
what is missing and refuses to replace a key that already exists. there is a
test in `tests/upgrade.sh` that installs, fingerprints every byte of a store,
installs again over the top, and fails if anything changed. it runs in ci on
every platform.

## the normal upgrade

~~~bash
secret-update --check     # what would happen, changes nothing
secret-update             # asks before it does anything
~~~

`--check` prints the plan: which checkout you installed from, which commits are
waiting on the remote, which migrations are pending, and whether the privileged
helper will need attention afterwards.

`secret-update` deliberately does **not** `git pull` for you. it tells you what
is new and leaves the decision where it belongs; run `git -C <checkout> pull
--ff-only` yourself and then `secret-update` again.

### if you are hardened

the root-owned helper is installed separately, under sudo, so an upgrade that
replaces the commands leaves it behind. `secret-update` says so, and the fix is
one line:

~~~bash
sudo ~/.local/libexec/agent-secrets-install-root
~~~

you do not have to guess whether you need this. the commands refuse to run
against a helper that is too old and name the command that fixes it, and
`secret-doctor` reports the protocol version either way.

## three version numbers

they answer different questions, and it is worth knowing which one is talking
to you.

| number | where it lives | what it means |
|---|---|---|
| release | `VERSION`, copied into `~/.local/bin/secret-manifest` | what you installed. quote it in a bug report. |
| helper protocol | `HELPER_PROTOCOL` in the helper | the contract between the commands and the root-owned helper. mismatches happen because they are installed by two different commands. |
| store format | `~/.secrets/.store-version` | the on-disk layout of your store. the only one that can require a migration. |

a store with no `.store-version` predates all of this. it is format 0, and the
first migration adopts it.

## migrations

a migration is a numbered script in `migrations/`, run in order when your
store's format is behind the code's. the rules are enforced by review and
stated in `migrations/readme.md`:

1. a migration **never** reads, rewrites or re-encrypts a scope. anything that
   needs plaintext is a conversion, not a migration, and belongs behind a
   command you run on purpose.
2. a migration is idempotent.
3. a migration never touches `key/`.

before any migration runs, `secret-update` copies `scopes/` and `index/` to
`~/.secrets/backups/<timestamp>/` and tells you where. if a migration fails,
the store version is not advanced, so it runs again next time rather than
leaving you half-migrated.

the backup does **not** include the key. a second copy of the key on the same
disk is a bigger risk than the one it would insure against, and in hardened
mode the key is root-owned and this command could not copy it anyway. back the
key up yourself, somewhere else, once.

## what is not covered

`secret-update` upgrades an install that recorded where it came from. an
install from before `secret-manifest` existed has no such record, and the
command says so and tells you to clone and run `./install.sh` once. your store
is not involved in that either way.
