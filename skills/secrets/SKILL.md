---
name: secrets
description: inspect and use locally encrypted secret scopes without printing secret values.
---

# secrets

use the installed commands instead of reading a .env.gpg file or the key directly.

start with:

~~~bash
secret-list <scope> --tree
~~~

it shows groups, key names, descriptions, attributes, and sensitivity marks without decrypting a value.

use the narrowest group that the task needs:

~~~bash
secret-run <scope> <group> -- <command> [args...]
~~~

a command without a group receives every value in the scope. do not use that form unless the task needs the whole scope.

never print values. do not run secret-run with env, printenv, set, or a command that logs its environment. do not read the key or decrypt a scope directly.

sensitive groups need a local approval. if the task knows it needs several groups, inspect the tree and batch them:

~~~bash
secret-approve <scope> --motive "run the requested check" <group> [<group>...]
~~~

approval exit codes:

- 69: no local approval session is available.
- 75: the dialog timed out or failed. one retry is okay.
- 77: approval was denied. stop and ask the store owner.
- 78: the index is stale or the metadata is malformed. run secret-reindex <scope>.

to store a new value, pipe it on stdin:

~~~bash
openssl rand -base64 32 | secret-set <scope> <group.path.key> --desc "what it is for"
~~~

do not pass a value in a flag or command argument.

the plaintext index is a display cache. after any out-of-band scope change, run:

~~~bash
secret-reindex <scope>
~~~
