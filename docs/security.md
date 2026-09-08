# security

this tool protects a local encrypted store. it has sharp limits.

## what the root install changes

before the root install, your account owns ~/.secrets/key/.key. any program that runs as you can read it or replace the local helper. the approval dialog catches mistakes, but it cannot stop a hostile process.

after the root install, root owns both the installed helper and the key. a process running as you cannot decrypt a scope directly. it can invoke the helper through its narrow sudo rule, but the helper validates scope and group names, checks the encrypted metadata, and asks for local approval before a sensitive group is released.

approval is a local consent check. after you approve, the selected process receives the selected values. read the exact command before approving it.

## the approval gate

the gate needs an active, unlocked, local desktop session and kdialog. it exits instead of guessing when no safe approval channel exists.

- 69 means there is no local approval channel.
- 75 means the dialog timed out or failed. nothing was cached.
- 77 means approval was denied. stop rather than retrying.
- 78 means an index is stale or metadata is malformed.

the gate uses the encrypted scope metadata, not the writable index. it caches an approval per sensitive group for 15 minutes by default. a sensitive parent covers all of its children.

## handling values

do not put a value in an argument, shell history, commit, issue, chat transcript, or log. use stdin with secret-set.

do not run a scope with commands that print its environment:

~~~text
env
printenv
set
~~~

use secret-list scope --tree to learn what exists. it reads an index that contains key names, groups, descriptions, attributes, and sensitivity marks, but no secret values.

## backup and recovery

a scope is an ordinary .env payload encrypted with gpg symmetric encryption. encrypted scope files may be backed up or synced. the key must be backed up separately and kept out of broad sync directories.

if you restore or edit a scope outside this tool, run:

~~~bash
secret-reindex scope
~~~

without the key, the encrypted scopes cannot be recovered. with both the key and scope files, gpg can decrypt the payload even if these scripts are unavailable.

## before publishing a fork

check that the repository has no .gpg files, .key files, .env files, local rclone configuration, ssh private keys, or scope indexes copied from a real store. the included .gitignore blocks common accidents, but it is not a substitute for reviewing git status.
