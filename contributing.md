# contributing

keep the repository free of encrypted scopes, keys, indexes from real stores, ssh keys, and rclone configuration.

run the smoke test before opening a pull request:

~~~bash
./tests/smoke.sh
~~~

run the root installer only on a disposable test account or your own machine. it writes to /usr/local/libexec and /etc/sudoers.d.

keep command output and prose lowercase. uppercase remains where an external format requires it, including .env variable names, systemd directive names, and environment variable names.

if a change alters the scope format or approval behavior, update docs/format.md, docs/security.md, and skills/secrets/SKILL.md in the same pull request.
