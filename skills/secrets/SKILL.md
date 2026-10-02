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

when the values the command needs live in more than one group, name them all in one run. they do not have to be one subtree:

~~~bash
secret-run <scope> <group> <group> [<group>...] -- <command> [args...]
~~~

the command gets those groups and nothing else, and the gate is the union of what they carry, so several groups still cost at most one dialog. **do not nest one `secret-run` inside another to combine groups.** the inner run starts from an empty environment and the outer group's variables are gone.

**for a read, look for a `mode=ro` role first.** these are the `.ro` groups in the tree, and they are normally ungated, so a read task should cost no approval at all. reaching for a write or app role to run a `SELECT` is what turns a read into a dialog.

a group that does not exist is an error, not an empty environment. if `secret-run` says `no group '<path>'`, browse with `secret-list` rather than falling back to the whole scope.

never print values. do not run secret-run with env, printenv, set, or a command that logs its environment. do not read the key or decrypt a scope directly.

sensitive groups need a local approval. `secret-run` with several groups already batches its own, so this is for approving ahead of a sequence of separate commands:

~~~bash
secret-approve <scope> --motive "run the requested check" <group> [<group>...]
~~~

an approval lasts 15 minutes after its last use, and every use starts that again, so steady work through one group costs one dialog. if the task will need a sensitive group on and off for longer than that (a long migration, a deploy you will check on), ask once for the time it needs instead of going back to the owner every 15 minutes:

~~~bash
secret-run <scope> <group> --for 2h -- <command>
secret-approve <scope> --motive "deploy and watch it" --for 2h <group>
~~~

`--for` takes `30m`, `2h` and so on, up to `12h`. ask for what the task needs, not the maximum: the owner sees the number and can choose the usual 15 minutes instead.

when you are done with a sensitive group well before its window runs out, lock it again:

~~~bash
secret-approve <scope> --revoke <group>
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

the path is not a label. the last segment is the key and everything before it is the group, so `pg.aws.mcps.RW_PASS` is stored as `PG_AWS_MCPS_RW_PASS` in the group `pg.aws.mcps`. browse first and reuse the shape that is already there:

~~~bash
secret-list <scope> --tree
~~~

**if the group does not exist yet, create it in the same write.** say what it holds with `--group-desc`, and the group is declared along with the key. there is nothing to hand to joel and nothing to edit:

~~~bash
openssl rand -base64 32 | secret-set <scope> stripe.live.WEBHOOK_SECRET --desc "signs webhook payloads" --group-desc "stripe, live mode"
secret-ask <scope> stripe.live.SECRET_KEY --desc "live secret key" --group-desc "stripe, live mode" stripe.live.PUBLISHABLE_KEY
~~~

without `--group-desc` a write into a group that does not exist is refused, and the refusal lists the nearest groups that do. that is on purpose: usually it means a typo, or a group that already exists under another name. either pick one of those, or add `--group-desc` if a new group really is right.

the write is also refused when the key would not end up in the group its path names. that happens when a deeper group's prefix matches the key (`stripe.live.webhook` takes `STRIPE_LIVE_WEBHOOK_URL`), when a new group would take a key out of another group, or when two groups would claim the same prefix (`pg.prod` and `pg_prod`). the message says which. pick another key or group name rather than working around it.

**a key written with no group path sits at the root of the scope, and nothing can narrow to it.** the only way to read it is `--all-groups`, which has to clear every sensitive group in the scope first. one ungrouped key turns every task that needs it into a whole-scope approval. always give a path. a write without one says so when it lands.

conventions worth matching:

- one group per thing with its own credentials: a service, a database, a host.
- postgres roles go under `pg.<server>.<database>.<role>`, where the role segment is its mode: `.ro` read-only, `.rw` read-write, `.app` the owning app role.
- describe the group, not just the key. the description is what the next reader chooses from, and what the approval dialog shows.

### declaring groups and marks

`--desc` covers the key, and `--group-desc` declares a new group with its description. replacing a key with `--force --desc` replaces its description too.

everything else about a group or key has its own command. none of them read or write a value, and **none of them need joel to open an editor**. never ask him to hand-edit a scope to add a group, a description, an attribute or a mark:

~~~bash
secret-group <scope> <group> --desc "what it holds" [--attr name=value]... [--sensitive [--ttl 30m]]
secret-meta  <scope> <group|KEY> [--desc "..."] [--attr name=value]... [--unset-attr name]
secret-meta  <scope> <group|KEY> --sensitive [--ttl 30m] | --not-sensitive | --ttl 30m
~~~

a group is named by its dotted path, a key by its variable name as `secret-list --keys` prints it.

`secret-group` declares a group that does not exist yet. keys already named for it move in: loose ones always, and keys sitting in another group only with `--take`, since that is a reorganisation and should be asked for as one. it says which keys it took. this is also how to put loose keys into a group without renaming them: declare the group whose prefix they already have.

add `--dry-run` to either command to see what would change and which prompts it would open, without changing anything. do that before anything that touches a sensitive group.

what they ask:

- adding a mark or shortening a TTL asks nothing, with one exception: a group mark that takes over from a key's own mark asks every time, since the dialog would show the group's description instead of the key's.
- a description or attribute on anything a marked group guards asks as a change. descriptions are what the approval dialog shows, so they are guarded like the values.
- removing a mark, lengthening a TTL, or declaring a group that takes a key out from under a marked one asks every time.

### moving and removing

a key that is in the wrong group, or in none, moves with `secret-mv`. its destination is a dotted path, the same shape `secret-set` takes, and `--group-desc` creates the group on the way if it does not exist:

~~~bash
secret-mv <scope> OPENAI_KEY ai.openai.API_KEY --group-desc "openai"
secret-mv <scope> stage pg.stage                 # a whole group, and everything under it
secret-mv <scope> A x.ONE B x.TWO                # several at once: one change, at most one dialog
~~~

**moving renames the variable.** `OPENAI_KEY` above becomes `AI_OPENAI_API_KEY`, and anything that reads `$OPENAI_KEY` stops finding it. before moving a key, find what reads it (grep the repo, the deploy config, the shell scripts) and change those in the same piece of work, or ask joel whether the rename is wanted. `--copy` keeps the original, which is the gentler way to migrate a consumer. a key whose name already matches the group needs no move: `secret-group` takes it as it is.

~~~bash
secret-rm <scope> OLD_TOKEN                      # a key, value and all. no undo
secret-rm <scope> stage                          # the declaration only. keys move up, and it says where
secret-rm <scope> stage --with-keys              # the group, its subgroups and every key in them
~~~

both take `--dry-run`. a move or removal inside a marked group asks as a change; one that leaves a key behind less than before (moving it out from under a mark, copying it somewhere unguarded, removing a marked group's declaration) asks every time.

the `#@` lines underneath, for reading a scope or for joel editing one by hand:

~~~
#@g <dotted.path>  <description>    declare a group
#@d <text>                          describe the next declaration
#@a <name>=<value>                  attribute of the next declaration
#@sensitive [ttl=<seconds>]         gate the next declaration
~~~

`pg-hosts` reads the `server`, `kind` (`endpoint`/`database`/`role`) and `mode` (`ro`/`rw`) attributes. a postgres role with no `mode=ro` is not offered as a read-only option anywhere, which is how a read task ends up reaching for a gated write role.

mark what would be damaging to leak. sensitivity inherits downward and a child cannot opt out, so marking a whole server also gates its read-only roles — worth knowing before marking at that level.

writing follows the destination: storing a value inside a sensitive group asks for approval, about that group. storing one anywhere else asks for nothing. a write never hands a value back, so it is not gated like a read.

anything that leaves a key less protected asks every time, whatever was approved before: removing a mark, lengthening a TTL, or declaring a group whose prefix pulls a key out from under a marked group. if you get a 77 there, the owner said no to losing that protection. stop and ask rather than finding another route to the same layout.

a write approval and a read approval are separate answers. getting a value stored in a sensitive group does not mean `secret-run` on that group will go through without a dialog, and an approved read does not cover a write.

the plaintext index is a display cache. after any out-of-band scope change, run:

~~~bash
secret-reindex <scope>
~~~
