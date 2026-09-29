# sm-chatlog

SourceMod plugin that records every player `say` and `say_team` into the regional MariaDB database named `chat`.

`databases.cfg` needs a block named `chat` (the panel template emits one per `db_plugins` entry). The plugin connects with `Database.Connect(..., "chat")` and creates `chat_logs` on connect.

```
spcomp -i scripting/include scripting/chatlog.sp -o plugins/chatlog.smx
```

SteamWorks must be loaded. The public IP plus `hostport` is stored as `server_ip` so it matches the whois `ip:port` key.
