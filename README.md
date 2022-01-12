# TPT Discord Verifier

## Hosting the bot

The bot is meant to be run on _anything but Windows_ ([a limitation of
cqueues](http://25thandclement.com/~william/projects/cqueues.html)) using
[Lua 5.3](https://www.lua.org/versions.html#5.3) or above. It has a number of
dependencies, namely:

 * `lunajson`
 * `http`
 * `lsqlite3`
 * `html-entities`

If you have [LuaRocks](https://luarocks.org/), you can install these with:

```sh
sudo luarocks install --lua-version=5.3 --tree=system lunajson
sudo luarocks install --lua-version=5.3 --tree=system http
sudo luarocks install --lua-version=5.3 --tree=system lsqlite3
sudo luarocks install --lua-version=5.3 --tree=system html-entities
```

Bot OAuth2 URL:
`https://discord.com/api/oauth2/authorize?client_id=CLIENT_ID_HERE&permissions=402656256&scope=bot+applications.commands+applications.commands.permissions.update`.
Don't forget to change `CLIENT_ID_HERE`.
