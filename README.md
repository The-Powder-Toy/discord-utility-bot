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
 * `lrexlib-pcre2`

If you have [LuaRocks](https://luarocks.org/), you can install these with:

```sh
sudo luarocks install --lua-version=5.3 --tree=system lunajson
sudo luarocks install --lua-version=5.3 --tree=system http
sudo luarocks install --lua-version=5.3 --tree=system lsqlite3
sudo luarocks install --lua-version=5.3 --tree=system html-entities
sudo luarocks install --lua-version=5.3 --tree=system lrexlib-pcre2
```

Bot OAuth2 URL:

```
https://discord.com/api/oauth2/authorize?client_id=CLIENT_ID_HERE&permissions=402656256&scope=bot+applications.commands+applications.commands.permissions.update
```

Don't forget to change `CLIENT_ID_HERE`.

The bot requires a `secret_config.lua` to be present in its working directory, structured as follows:

```lua
return {
    maintainer_id        = "000000000000000000", -- whom to ping if the bot dies
    app_id               = "000000000000000001", -- see discord documentation
    app_token            = "aaaaaaaaaaaahowareyouholdingupaaaaaaaaa", -- see discord documentation
    oauth_id             = "000000000000000002", -- see discord documentation
    oauth_secret         = "bbbbbbbbbbbbbbbbbbbbbbagelsbbbbbbbbbbbbbbbb", -- see discord documentation
    guild_id             = "000000000000000003", -- guild to operate in
    managed_role_id      = "000000000000000004", -- role to manage (Verified)
    user_role_ids        = { "000000000000000004", "000000000000000005", "000000000000000006" }, -- roles to accept Verified-only requests from
    mod_role_ids         = { "000000000000000007", "000000000000000008" }, -- roles to accept Mod-only requests from
    welcome_id           = "000000000000000009", -- channel to send welcome messages to (#welcome)
    verification_id      = "000000000000000010", -- channel to send verification requests to (#verification)
    embed_muted_role_ids = { "000000000000000011", "000000000000000012" }, -- roles to ignore embed request from
    backend_audience     = "ccccccccpotatoccccccc", -- backend audience (contact the backend maintainer for further info)
    backend_base         = "https://example.com", -- backend url (contact the backend maintainer for further info)
    http_listen_addr     = "0.0.0.0", -- listen address of the web server that receives redirects from the backend
    http_listen_port     = 1337, -- listen port of the web server that receives redirects from the backend
    theme_color          = 0xABCDEF, -- theme colour to use in all embeds
}
```
