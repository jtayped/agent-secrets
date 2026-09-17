---
name: secrets
description: inspect and use locally encrypted secret scopes without printing secret values.
---

# secrets

use the installed commands instead of reading a .env.gpg file or the key directly.

browse before you guess. `secret-list` works like `ls` and never decrypts a value:

~~~bash
secret-list                      # every scope
secret-list <scope>              # the top level of that scope
secret-list <scope> <group>      # one level inside that group
~~~

each subgroup line carries a count of what is beneath it and a description, which is usually enough to pick the right branch in one or two steps. drill down until you find the group the task needs.

`secret-list <scope> [<group>] --tree` prints a whole subtree at once. prefer the level view while exploring; a large scope's tree is long enough to be worth avoiding unless you already know the shape.

use the narrowest group that the task needs:

~~~bash
secret-run <scope> <group> -- <command> [args...]
~~~

the group is required. a run that names none is refused, because without one the command receives every value in the scope and the gate has to clear every sensitive group in it to hand them over. the refusal lists the read-only roles you could have used instead. if the task really does need the whole scope, say so with `--all-groups` — it is the only form that reaches keys sitting outside any group.

**for a read, look for a `mode=ro` role first.** these are the `.ro` groups in the tree, and they are normally ungated, so a read task should cost no approval at all. reaching for a write or app role to run a `SELECT` is what turns a read into a dialog.

a group that does not exist is an error, not an empty environment. if `secret-run` says `no group '<path>'`, browse with `secret-list` rather than falling back to the whole scope.

never print values. do not run secret-run with env, printenv, set, or a command that logs its environment. do not read the key or decrypt a scope directly.

sensitive groups need a local approval. if the task knows it needs several groups, find them first and then batch them:

~~~bash
secret-approve <scope> --motive "run the requested check" <group> [<group>...]
~~~

approval exit codes:

- 69: no local approval session is available.
- 75: the dialog timed out or failed. one retry is okay.
- 77: approval was denied. stop and ask the store owner.
- 78: the index is stale or the metadata is malformed. run secret-reindex <scope>.

## adding a secret

if the value can be generated or is already on the machine, pipe it on stdin. never put it in a flag or an argument: that lands in `ps`, in shell history, and in this transcript.

~~~bash
openssl rand -base64 32 | secret-set <scope> <group.path.KEY> --desc "what it is for"
~~~

**if joel has to supply the value himself, use `secret-ask` instead of handing him a `secret-set` command to paste into.** a pasted credential ends up in his shell history and in this transcript, which is the thing the store exists to avoid.

~~~bash
secret-ask <scope> <group.path.KEY> --desc "what it is for"
~~~

this opens a masked dialog on his screen showing the scope, the variable name and the description. the value goes from the dialog into the encrypted store without passing through the command line or this session. you learn only that it was stored. it refuses an existing key before asking rather than after; pass `--force` to replace one deliberately.

ask for related credentials together rather than one command at a time. `--desc` attaches to the path in front of it, one approval covers the set, and either every value is stored or none is:

~~~bash
secret-ask <scope> <group>.USER --desc "login" <group>.PASS --desc "password"
~~~

either way the group path matters as much as the value:

### pick the group before you write

the path is not a label. it becomes the variable name, so `pg.aws.mcps.RW_PASS` is stored as `PG_AWS_MCPS_RW_PASS`, and the key then belongs to the longest declared group matching that prefix. browse first and reuse the shape that is already there:

~~~bash
secret-list <scope> --tree
~~~

**a key written with no group path sits at the root of the scope, and nothing can narrow to it.** the only way to read it is `--all-groups`, which has to clear every sensitive group in the scope first. one ungrouped key turns every task that needs it into a whole-scope approval. always give a path.

conventions worth matching:

- one group per thing with its own credentials: a service, a database, a host.
- postgres roles go under `pg.<server>.<database>.<role>`, where the role segment is its mode: `.ro` read-only, `.rw` read-write, `.app` the owning app role.
- describe the group, not just the key. the description is what the next reader chooses from, and what the approval dialog shows.

### declaring groups and marks

`--desc` covers the key. a group, an attribute or a sensitivity mark is a `#@` line, which means `secret-edit`. edit the group, not the scope — a large scope opens four lines instead of a hundred:

~~~bash
secret-edit <scope> <group>
~~~

~~~
#@g <dotted.path>  <description>    declare a group
#@d <text>                          describe the next declaration
#@a <name>=<value>                  attribute of the next declaration
#@sensitive [ttl=<seconds>]         gate the next declaration
~~~

the last three attach to the **next** declaration, which is either a `#@g` line or a `KEY=` line, so a group's header block sits above it. hand-writing these is easy to get one line off; every save re-renders the file in canonical order, so the first save after a hand edit fixes the layout.

`pg-hosts` reads the `server`, `kind` (`endpoint`/`database`/`role`) and `mode` (`ro`/`rw`) attributes. a postgres role with no `mode=ro` is not offered as a read-only option anywhere, which is how a read task ends up reaching for a gated write role.

mark what would be damaging to leak. sensitivity inherits downward and a child cannot opt out, so marking a whole server also gates its read-only roles — worth knowing before marking at that level.

writing follows the destination: storing a value inside a sensitive group asks for approval, about that group. storing one anywhere else asks for nothing. a write never hands a value back, so it is not gated like a read.

the plaintext index is a display cache. after any out-of-band scope change, run:

~~~bash
secret-reindex <scope>
~~~
