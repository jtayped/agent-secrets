# agent-secrets

a small bash tool for encrypted .env scopes.

it keeps each scope in one gpg-encrypted file, with a separate 32-byte key. commands can list group and key metadata without decrypting anything. a root-owned helper can require a local desktop approval before a sensitive group reaches an editor or child process.

this is aimed at one person on one machine. it is not a shared secret manager and it does not replace backups, access controls, or a review of the command that will receive a secret.

## install

clone the repository, then run:

~~~bash
./install.sh
~~~

the installer puts commands in ~/.local/bin and its helper in ~/.local/libexec. it also creates ~/.secrets and a new key if one does not exist.

make sure ~/.local/bin is on your path. for bash, add this to ~/.bashrc if needed:

~~~bash
export PATH="$HOME/.local/bin:$PATH"
~~~

create a first scope with your normal editor:

~~~bash
secret-edit example --new
~~~

add plain .env entries, save, then inspect the value-free tree:

~~~bash
secret-list example --tree
~~~

to make the decryption key root-owned and enable the approval gate as a real local control, run:

~~~bash
sudo ~/.local/libexec/agent-secrets-install-root
secret-helper-status
~~~

the root step is optional for a first trial, but it is the setup worth keeping. [the setup guide](docs/setup.md) has the full sequence.

## commands

~~~text
secret-init
secret-list [scope] [--tree]
secret-edit scope [group | --new]
secret-set scope group.path.key [--desc text] [--force]
secret-approve scope --motive "short reason" group [group...]
secret-run scope [group] [--motive "short reason"] -- command [args...]
secret-reindex [scope...]
secret-doctor
pg-hosts [server | --scope scope]
ssh-hosts [alias]
secrets-bisync
secret-helper-status
~~~

use secret-run to give a command only the group it needs:

~~~bash
secret-run example service.api -- curl -fsS https://api.example.test/me
~~~

never use it with env, printenv, set, or another command whose job is to print the environment.

## store layout

~~~text
~/.secrets/
  scopes/       encrypted .env payloads
  index/        key names, groups, descriptions, and sensitivity marks
  key/.key      the 32-byte gpg key
~~~

the index contains no values. it is safe to read, but it can go stale after an out-of-band scope change. run secret-reindex after restoring or replacing a .env.gpg file.

back up scopes/ and key/.key separately. do not put key/ in a broad sync folder or this repository.

## skill

[skills/secrets/SKILL.md](skills/secrets/SKILL.md) is a portable skill file for coding agents. copy it into the agent's skill directory after installing the commands. it tells an agent how to discover metadata, narrow a group, and avoid printing values.

## platforms

linux and macos are supported. windows is supported through wsl2 and not
natively, because the protection here is posix file ownership plus sudo plus a
root-owned helper, and a git-bash install would report success while protecting
nothing.

run `secret-doctor` to see exactly what your machine can do and what it is
missing. [compatibility.md](docs/compatibility.md) has the full matrix,
including the one caveat that keeps hardened mode off most macs.

## notes

- the approval dialog only works from an active, unlocked local desktop session.
- rclone is optional and only used by secrets-bisync.
- the tool does not store values in this repository.

read [security.md](docs/security.md) before trusting the root install. the honest limits matter here.
