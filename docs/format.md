# scope format

a decrypted scope is a plain .env file with optional metadata comments. values stay on one line.

~~~dotenv
#@g service.api  api credentials
#@a owner=platform
#@d token used by the deployment client
SERVICE_API_TOKEN=replace-me
~~~

metadata attaches to the next group or key declaration.

~~~text
#@g dotted.path  declares a group
#@d text          describes the next declaration
#@a name=value    adds an attribute to the next declaration
#@sensitive       marks the next declaration as sensitive
~~~

a group path maps to an uppercase variable prefix. service.api maps to SERVICE_API_. the longest matching declared group owns a key. a key without a matching group is ungrouped.

attributes make the postgres view useful:

~~~dotenv
#@a server=demo
#@a kind=endpoint
#@g pg.demo  example postgres endpoint
PG_DEMO_HOST=database.example.test
PG_DEMO_PORT=5432

#@a kind=role
#@a mode=rw
#@g pg.demo.app  application role
PG_DEMO_APP_USER=app
PG_DEMO_APP_PASSWORD=replace-me
~~~

pg-hosts reads the server, kind, and mode attributes from the value-free index. it never decrypts a scope.
