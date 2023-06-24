#!/usr/bin/env lua5.3

setmetatable(_G, { __index = function(_, key)
	error("__index on _G: " .. tostring(key))
end, __newindex = function(_, key)
	error("__newindex on _G: " .. tostring(key))
end })

math.randomseed(os.time())

local cqueues           = require("cqueues")
local discord           = require("discord")
local logger            = require("logger")
local openssl_rand      = require("openssl.rand")
local config            = require("config")
local secret_config     = require("secret_config")
local basexx            = require("basexx")
local http_headers      = require("http.headers")
local http_server       = require("http.server")
local http_util         = require("http.util")
local http_cookie       = require("http.cookie")
local http_request      = require("http.request")
local lpeg_patterns_uri = require("lpeg_patterns.uri")
local lunajson          = require("lunajson")
local powder            = require("powder")
local util              = require("util")
local db                = require("db")
local html_entities     = require("htmlEntities")

assert(openssl_rand.ready())

local guild_members = {}
local subst = util.subst
local log   = logger.new(print)
local moderators_str
do
	local moderators = {}
	for i = 1, #secret_config.mod_role_ids do
		table.insert(moderators, subst("<@&$>", secret_config.mod_role_ids[i]))
	end
	moderators_str = table.concat(moderators, ", ")
end

local dbh = db.handle("tptutilitybot.sqlite3")

local function db_connect(log, duser, tuser, tname)
	return dbh:exec(log:sub("connecting duser $ with tuser $ aka $", duser, tuser, tname), [[INSERT INTO connections ("duser", "tuser", "tname", "stale") values (?, ?, ?, 0)]], duser, tuser, tname)
end

local function db_tnameupdate(log, duser, tname)
	return dbh:exec(log:sub("updating tname of duser $ to $ and unmarking it stale", duser, tname), [[UPDATE connections SET "stale" = 0, "tname" = ? WHERE "duser" = ?]], tname, duser)
end

local function db_markstale(log, duser)
	return dbh:exec(log:sub("marking duser $ stale", duser), [[UPDATE connections SET "stale" = 1 WHERE "duser" = ?]], duser)
end

local function db_whois(log, duser)
	return dbh:exec(log:sub("looking up duser $", duser), [[SELECT * FROM connections WHERE "duser" = ?]], duser)
end

local function db_rwhois(log, tuser)
	return dbh:exec(log:sub("looking up tuser $", tuser), [[SELECT * FROM connections WHERE "tuser" = ? COLLATE NOCASE]], tuser)
end

local function db_disconnect(log, duser)
	return dbh:exec(log:sub("disconnecting duser $", duser), [[DELETE FROM connections WHERE "duser" = ?]], duser)
end

local function db_rdisconnect(log, tuser)
	return dbh:exec(log:sub("disconnecting tuser $", tuser), [[DELETE FROM connections WHERE "tuser" = ? COLLATE NOCASE]], tuser)
end

local function db_random_nonstale(log)
	return dbh:exec(log:sub("selecting random user"), [[SELECT * FROM connections WHERE "stale" = 0 ORDER BY random() LIMIT 1]])
end

local function array_intersect(arr1, arr2)
	for i = 1, #arr1 do
		for j = 1, #arr2 do
			if arr1[i] == arr2[j] then
				return true
			end
		end
	end
end

local ident_token_counter = 0
local ident_tokens = {}
local duser_to_ident_token = {}

local function invalidate_ident_token(log, ident_token)
	log("invalidating ident token $", ident_tokens[ident_token].unique)
	duser_to_ident_token[ident_tokens[ident_token].user.id] = nil
	ident_tokens[ident_token] = nil
end

local function prune_iat_table(tbl, max_age, kill_func)
	local to_kill = {}
	local now = cqueues.monotime()
	for key, value in pairs(tbl) do
		if value.iat + max_age < now then
			to_kill[key] = true
		end
	end
	for key in pairs(to_kill) do
		kill_func(key)
	end
end

dbh:exec(log:sub("setting up db"), [[CREATE TABLE IF NOT EXISTS connections(
	"duser" STRING NOT NULL,
	"tuser" INTEGER NOT NULL,
	"tname" STRING NOT NULL,
	unique ("duser"),
	unique ("tuser")
)]])

local cli

local function give_role(log, duser)
	local log = log:sub("giving managed role to duser $", duser)
	local data, errcode, errbody = cli:assign_user_role(secret_config.guild_id, duser, secret_config.managed_role_id)
	if not data then
		log("failed: status $: $", errcode, errbody)
	end
	return data, errcode, errbody
end

local function take_role(log, duser)
	local log = log:sub("taking managed role from duser $", duser)
	local data, errcode, errbody = cli:unassign_user_role(secret_config.guild_id, duser, secret_config.managed_role_id)
	if not data then
		log("failed: status $: $", errcode, errbody)
	end
	return data, errcode, errbody
end

local function set_nick(log, duser, nick)
	local log = log:sub("setting nick of duser $ to $", duser, nick)
	local data, errcode, errbody = cli:set_user_nick(secret_config.guild_id, duser, nick)
	if not data then
		log("failed: status $: $", errcode, errbody)
	end
	return data, errcode, errbody
end

local function get_effective_dname(duser, dname)
	local log = log:sub("getting effective dname of duser $", duser)
	local nick, errcode, errbody = cli:get_user_nick(secret_config.guild_id, duser)
	if nick == nil then
		log("failed: status $: $", errcode, errbody)
		return nil, errcode, errbody
	end
	return nick or dname, errcode, errbody
end

local function assert_api_fetch(data, errcode, errbody)
	if not data then
		error(subst("error: code $: $", errcode, errbody))
	end
	return data
end

local WHOISCTX_NAME = "Powder Toy Profile"
local GETRQUSER_NAME = "Get Requesting User"
local can_use_command = {
	setnick            = secret_config.user_role_ids,
	ping               = secret_config.user_role_ids,
	whois              = secret_config.user_role_ids,
	[ WHOISCTX_NAME ]  = secret_config.user_role_ids,
	rwhois             = secret_config.user_role_ids,
	identmod           = secret_config.mod_role_ids,
	[ GETRQUSER_NAME ] = secret_config.mod_role_ids,
}
local command_custom_ids = {
	verify = "verify",
	setnick = "setnick",
}
local command_ids = {}
local function register_commands()
	local data = assert_api_fetch(cli:set_application_commands(secret_config.guild_id, {
		{
			name = "verify",
			description = "Verify yourself by connecting your Powder Toy account",
			options = util.make_array({}),
		},
		{
			name = "ping",
			description = "Ping the Utility Bot",
			options = util.make_array({}),
		},
		{
			name = "setnick",
			description = "Set your Powder Toy name as your nickname",
			options = util.make_array({}),
		},
		{
			name = "whois",
			description = "Look up a Powder Toy user based on a Discord user",
			options = {
				{
					name = "duser",
					description = "Discord user to look for",
					type = discord.command_option.USER,
					required = true,
				},
			},
		},
		{
			name = WHOISCTX_NAME,
			type = discord.command.USER,
		},
		{
			name = GETRQUSER_NAME,
			type = discord.command.MESSAGE,
		},
		{
			name = "rwhois",
			description = "Look up a Discord user based on a Powder Toy user",
			options = {
				{
					name = "tname",
					description = "Powder Toy user to look for",
					type = discord.command_option.STRING,
					required = true,
				},
			},
		},
		{
			name = "identmod",
			description = "Moderator command for managing Powder Toy account connections",
			options = {
				{
					name = "connect",
					description = "Connect a Discord user with a Powder Toy user",
					type = discord.command_option.SUB_COMMAND,
					options = {
						{
							name = "duser",
							description = "Discord user to connect",
							type = discord.command_option.USER,
							required = true,
						},
						{
							name = "tname",
							description = "Powder Toy user to connect with",
							type = discord.command_option.STRING,
							required = true,
						},
						{
							name = "giverole",
							description = "Give the Discord user the bot-managed role (defaults to true)",
							type = discord.command_option.BOOLEAN,
						},
					},
				},
				{
					name = "disconnect",
					description = "Disconnect a Discord user from the connected Powder Toy user",
					type = discord.command_option.SUB_COMMAND,
					options = {
						{
							name = "duser",
							description = "Discord user to disconnect",
							type = discord.command_option.USER,
							required = true,
						},
						{
							name = "takerole",
							description = "Take from Discord user the bot-managed role (defaults to true)",
							type = discord.command_option.BOOLEAN,
						},
					},
				},
				{
					name = "rdisconnect",
					description = "Disconnect a Powder Toy user from the connected Discord user",
					type = discord.command_option.SUB_COMMAND,
					options = {
						{
							name = "tname",
							description = "Powder Toy user to disconnect",
							type = discord.command_option.STRING,
							required = true,
						},
						{
							name = "takerole",
							description = "Take from Discord user the bot-managed role (defaults to true)",
							type = discord.command_option.BOOLEAN,
						},
					},
				},
				{
					name = "dwhois",
					description = "Look up a Powder Toy user based on a Discord user ID",
					type = discord.command_option.SUB_COMMAND,
					options = {
						{
							name = "duserid",
							description = "Discord user ID to look for",
							type = discord.command_option.STRING,
							required = true,
						},
					},
				},
			},
		},
	}))
	for _, command_data in pairs(data) do
		command_ids[command_data.name] = command_data.id
		if can_use_command[command_data.name] then
			local permissions = {
				{
					id = secret_config.guild_id, -- disable for everyone
					type = discord.command_permission.ROLE,
					permission = false,
				},
			}
			for _, role_id in pairs(can_use_command[command_data.name]) do
				table.insert(permissions, {
					id = role_id,
					type = discord.command_permission.ROLE,
					permission = true,
				})
			end
			assert_api_fetch(cli:set_command_permissions(secret_config.guild_id, command_data.id, {
				permissions = permissions,
			}))
		end
	end
end

local function discord_response_data(info)
	local data = {}
	data.content = info.content
	data.components = info.components
	data.flags = discord.interaction_response_flag.EPHEMERAL
	if info.url then
		assert(not data.components)
		data.components = {
			{
				type = discord.component.ACTION_ROW,
				components = {
					{
						type = discord.component.BUTTON,
						style = discord.component_button.LINK,
						url = info.url,
						label = info.label,
					},
				},
			},
		}
	end
	return data
end

local function discord_interaction_respond(data, info)
	return cli:create_interaction_response(data.id, data.token, {
		type = discord.interaction_response.CHANNEL_MESSAGE_WITH_SOURCE,
		data = discord_response_data(info),
	})
end

local function discord_interaction_followup(token, info)
	return cli:create_followup_message(token, discord_response_data(info))
end

local recheck_cache = {}
local function recheck_connection(log, record)
	if record then
		prune_iat_table(recheck_cache, config.bot.recheck_cache_max_age, function(duser)
			log("removing recheck cache entry for duser $: pruned", duser)
			recheck_cache[duser] = nil
		end)
		local log = log:sub("rechecking connection for duser $", record.duser)
		if recheck_cache[record.duser] then
			log("found recheck cache entry")
		else
			local tuser, err = powder.fetch_user(record.tname)
			if tuser == nil then
				log("backend fetch failed: $", err)
			elseif tuser == false or tuser.ID ~= record.tuser then
				if record.stale == 0 then
					local log = log:sub("$ has changed usernames, dropping connection", record.tname)
					if guild_members[record.duser] then
						local ok, errcode, errbody = cli:create_channel_message(secret_config.verification_id, discord_response_data({
							content = subst("<@$> You seem to have changed your username on Powder Toy. Use **/verify** or the button below to verify yourself again.", record.duser),
							components = {
								{
									type = discord.component.ACTION_ROW,
									components = {
										{
											type = discord.component.BUTTON,
											style = discord.component_button.PRIMARY,
											custom_id = command_custom_ids.verify,
											label = "Verify yourself again",
										},
									},
								},
							},
						}))
						if not ok then
							log("failed to notify user: code $: $", errcode, errbody)
						end
					end
					db_markstale(log, record.duser)
					take_role(log, record.duser)
					record.stale = 1
				end
			else
				local log = log:sub("$ has not changed usernames yet", record.tname)
				log("creating recheck cache entry for duser $", record.duser)
				recheck_cache[record.duser] = {
					iat = cqueues.monotime(),
				}
			end
		end
	end
	return record
end

local function appcommand_ident(log, data)
	local log = log:sub("appcommand_ident for duser $", data.member.user.id)
	local record = recheck_connection(log, db_whois(log, data.member.user.id)[1])
	local tnameupdate = false
	if record then
		if record.stale == 1 then
			tnameupdate = record.tuser
		else
			local log = log:sub("duser $ already has a tuser connected", data.member.user.id)
			local role_ok = give_role(log, data.member.user.id)
			local ok, errcode, errbody
			if role_ok then
				ok, errcode, errbody = discord_interaction_respond(data, {
					content = subst("Your Powder Toy account is already connected: $", record.tname),
					url     = subst("$/User.html?Name=$", secret_config.backend_base, record.tname),
					label   = subst("View $'s Powder Toy profile", record.tname),
				})
			else
				ok, errcode, errbody = discord_interaction_respond(data, {
					content = subst("Your Powder Toy account is already connected, but an error occurred while assigning the <@&$> role. Contact $ for help.", secret_config.managed_role_id, moderators_str),
				})
			end
			if not ok then
				log("failed to notify user: code $: $", errcode, errbody)
			end
			return
		end
	end
	if duser_to_ident_token[data.member.user.id] then
		local log = log:sub("duser $ already had an ident token, obsoleting", data.member.user.id)
		local ok, errcode, errbody = discord_interaction_followup(ident_tokens[duser_to_ident_token[data.member.user.id]].followup, {
			content = "This link has been invalidated by your requesting another one.",
		})
		if not ok then
			log("failed to notify user: code $: $", errcode, errbody)
		end
		invalidate_ident_token(log:sub("invalidating ident token: obsoleted"), duser_to_ident_token[data.member.user.id])
	end
	prune_iat_table(ident_tokens, config.bot.ident_token_max_age, function(token)
		invalidate_ident_token(log:sub("invalidating ident token for $: pruned", ident_tokens[token].user.id), token)
	end)
	local ident_token
	while true do
		ident_token = basexx.to_url64(openssl_rand.bytes(48))
		if not ident_tokens[ident_token] then
			break
		end
	end
	ident_token_counter = ident_token_counter + 1
	ident_tokens[ident_token] = {
		user = {
			id = data.member.user.id,
			username = data.member.user.username,
			discriminator = data.member.user.discriminator,
			global_name = data.member.user.global_name,
		},
		iat = cqueues.monotime(),
		followup = data.token,
		unique = ident_token_counter,
		tnameupdate = tnameupdate,
	}
	if tnameupdate then
		log("allocated ident tnameupdate token $ for duser $", ident_tokens[ident_token].unique, data.member.user.id)
	else
		log("allocated ident connect token $ for duser $", ident_tokens[ident_token].unique, data.member.user.id)
	end
	duser_to_ident_token[data.member.user.id] = ident_token
	local ok, errcode, errbody = discord_interaction_respond(data, {
		content = subst("Are you ready to connect your Powder Toy account? The link below will expire in $ minutes.", math.ceil(config.bot.ident_token_max_age / 60)),
		url     = subst("$/ExternalAuth.api?Action=Get&Audience=$&AppToken=$", secret_config.backend_base, secret_config.backend_audience, ident_token),
		label   = "Connect your Powder Toy account",
	})
	if not ok then
		invalidate_ident_token(log:sub("invalidating ident token: undelivered: code $: $", errcode, errbody), ident_token)
		return
	end
end

local function appcommand_setnick(log, data)
	local log = log:sub("appcommand_setnick for duser $", data.member.user.id)
	local record = recheck_connection(log, db_whois(log, data.member.user.id)[1])
	local ok, errcode, errbody
	if record then
		local edname = get_effective_dname(data.member.user.id, data.member.user.global_name)
		if not edname then
			ok, errcode, errbody = discord_interaction_respond(data, {
				content = "Your nickname could not be set. Contact " .. moderators_str .. " for help.",
			})
		elseif edname == record.tname then
			log("found duser $ with edname $ == tname $", data.member.user.id, edname, record.tname)
			ok, errcode, errbody = discord_interaction_respond(data, {
				content = "Your nickname already matches your Powder Toy name.",
			})
		else
			log("found duser $ with edname $ != tname $", data.member.user.id, edname, record.tname)
			local set_ok = set_nick(log, data.member.user.id, record.tname)
			if set_ok then
				ok, errcode, errbody = discord_interaction_respond(data, {
					content = "Done.",
				})
			else
				ok, errcode, errbody = discord_interaction_respond(data, {
					content = "Your nickname could not be set. Contact " .. moderators_str .. " for help.",
				})
			end
		end
	else
		log("duser $ not found", data.member.user.id)
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = subst("Your account has been disconnected, see the message in <#$>.", secret_config.verification_id),
		})
	end
	if not ok then
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local make_event_log
do
	local event_log_i = {}
	local event_log_m = { __index = event_log_i }

	function event_log_i:push(key, data)
		self.counter_ = self.counter_ + 1
		if self.log_[self.counter_ - self.max_entries_] then
			self.data_[self.log_[self.counter_ - self.max_entries_]] = nil
			self.log_[self.counter_ - self.max_entries_] = nil
		end
		self.data_[key] = data
		self.log_[self.counter_] = key
	end

	function event_log_i:get(key)
		return self.data_[key]
	end

	function make_event_log(max_entries)
		return setmetatable({
			max_entries_ = max_entries,
			counter_ = 0,
			data_ = {},
			log_ = {},
		}, event_log_m)
	end
end

local rquser_events = make_event_log(config.bot.rquser_max_log)
local function appcommand_getrquser(log, data)
	local dmsg = data.data.target_id
	local log = log:sub("appcommand_getrquser by duser $ for dmsg $", data.member.user.id, dmsg)
	local duser = rquser_events:get(dmsg)
	local ok, errcode, errbody
	if duser then
		log("found dmsg $: requested by duser $", dmsg, duser)
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = subst("Requested by <@$>.", duser),
		})
	else
		log("dmsg $ not found", dmsg)
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = subst("Not present in log."),
		})
	end
	if not ok then
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local function appcommand_whois(log, data)
	local duser
	if data.data.target_id then
		duser = data.data.target_id
	else
		for _, option in pairs(data.data.options) do
			if option.name == "duser" then
				duser = option.value
			end
		end
	end
	local log = log:sub("appcommand_whois by duser $ for duser $", data.member.user.id, duser)
	local record = recheck_connection(log, db_whois(log, duser)[1])
	local ok, errcode, errbody
	if record then
		if record.stale == 1 then
			log("found duser $: tname was $", duser, record.tname)
			ok, errcode, errbody = discord_interaction_respond(data, {
				content = subst("<@$> was $.", duser, record.tname),
			})
		else
			log("found duser $: tname is $", duser, record.tname)
			ok, errcode, errbody = discord_interaction_respond(data, {
				content = subst("<@$> is $.", duser, record.tname),
				url     = subst("$/User.html?Name=$", secret_config.backend_base, record.tname),
				label   = subst("View $'s Powder Toy profile", record.tname),
			})
		end
	else
		log("duser $ not found", duser)
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = subst("<@$> has not connected a Powder Toy account.", duser),
		})
	end
	if not ok then
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local function appcommand_identmod_dwhois(log, data)
	local duserid
	for _, option in pairs(data.data.options[1].options) do
		if option.name == "duserid" then
			duserid = option.value
		end
	end
	local log = log:sub("appcommand_identmod_dwhois by duser $ for duserid $", data.member.user.id, duserid)
	if not duserid:find("^[0-9]+$") then
		log("invalid snowflake $", duserid)
		local ok, errcode, errbody = discord_interaction_respond(data, {
			content = subst("$ does not look like a valid snowflake.", duserid),
		})
		if not ok then
			log("failed to notify user: code $: $", errcode, errbody)
		end
		return
	end
	appcommand_whois(log:sub("entering from dwhois"), {
		data = { target_id = duserid },
		member = data.member,
		id = data.id,
		token = data.token,
	})
end

local function appcommand_rwhois(log, data)
	local tname
	for _, option in pairs(data.data.options) do
		if option.name == "tname" then
			tname = option.value
		end
	end
	local log = log:sub("appcommand_rwhois by duser $ for tname $", data.member.user.id, tname)
	local tuser, err = powder.fetch_user(tname)
	local ok, errcode, errbody
	if tuser == nil then
		log("failed to fetch user: $", err)
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = "Backend error, try again later.",
		})
	elseif not tuser then
		log("no such user")
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = "No such user.",
		})
	else
		log("user found")
		local record = recheck_connection(log, db_rwhois(log, tuser.ID)[1])
		if record then
			if record.stale == 1 then
				log("found tuser $: duser was $", tuser.ID, record.duser)
				ok, errcode, errbody = discord_interaction_respond(data, {
					content = subst("$ was <@$>.", tuser.Username, record.duser),
				})
			else
				log("found tuser $: duser is $", tuser.ID, record.duser)
				ok, errcode, errbody = discord_interaction_respond(data, {
					content = subst("$ is <@$>.", tuser.Username, record.duser),
				})
			end
		else
			log("tuser $ not found", tuser.ID)
			ok, errcode, errbody = discord_interaction_respond(data, {
				content = subst("$ has not connected a Discord account.", tuser.Username),
			})
		end
	end
	if not ok then
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local function appcommand_identmod_connect(log, data)
	local duser, tname
	local giverole = true
	for _, option in pairs(data.data.options[1].options) do
		if option.name == "duser" then
			duser = option.value
		end
		if option.name == "tname" then
			tname = option.value
		end
		if option.name == "giverole" then
			giverole = option.value
		end
	end
	local log = log:sub("appcommand_identmod_connect by duser $ for duser $ and tname $ with giverole $", data.member.user.id, duser, tname, giverole)
	local tuser, err = powder.fetch_user(tname)
	if tuser == nil then
		log("backend fetch failed: $", err)
		local ok, errcode, errbody = discord_interaction_respond(data, {
			content = "Backend fetch failed, contact an administrator for help.",
		})
		if not ok then
			log("failed to notify user: code $: $", errcode, errbody)
		end
		return
	end
	local ok, errcode, errbody
	if tuser then
		log("found tname $, connecting", tname)
		local cok, cerr = db_connect(log, duser, tuser.ID, tuser.Username)
		if not cok then
			log("constraint violation")
			local record_from_duser = recheck_connection(log, db_whois(log, duser)[1])
			if record_from_duser then
				if record_from_duser.tuser == tuser.ID then
					log("found conflicting duser $ with matching tuser $", duser, tuser.ID)
					db_tnameupdate(log, duser, tuser.Username)
					cok = true
				else
					log("found conflicting duser $", duser)
					ok, errcode, errbody = discord_interaction_respond(data, {
						content = subst("<@$> has already connected a Powder Toy account, try disconnecting it first.", duser),
					})
				end
			elseif recheck_connection(log, db_rwhois(log, tuser.ID)[1]) then
				log("found conflicting tuser $", tuser.ID)
				ok, errcode, errbody = discord_interaction_respond(data, {
					content = subst("$ has already connected a Discord account, try disconnecting it first.", tuser.Username),
				})
			else
				log("found no conflicting entry, weird")
				ok, errcode, errbody = discord_interaction_respond(data, {
					content = "Database inconsistency detected. Try again, and if the issue persists, contact an administrator for help.",
				})
			end
		end
		if cok then
			if giverole then
				give_role(log, duser)
			end
			ok, errcode, errbody = discord_interaction_respond(data, {
				content = "Done.",
			})
		end
	else
		log("tname $ not found", tname)
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = "No such Powder Toy account.",
		})
	end
	if not ok then
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local function appcommand_identmod_disconnect(log, data)
	local duser
	local takerole = true
	for _, option in pairs(data.data.options[1].options) do
		if option.name == "duser" then
			duser = option.value
		end
		if option.name == "takerole" then
			takerole = option.value
		end
	end
	local log = log:sub("appcommand_identmod_disconnect by duser $ for duser $ with takerole $", data.member.user.id, duser, takerole)
	local record = recheck_connection(log, db_whois(log, duser)[1])
	local ok, errcode, errbody
	if record then
		log("found duser $, disconnecting", duser)
		db_disconnect(log, duser)
		if takerole then
			take_role(log, duser)
		end
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = "Done.",
		})
	else
		log("duser $ not found", duser)
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = subst("<@$> has not connected a Powder Toy account.", duser),
		})
	end
	if not ok then
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local function appcommand_identmod_rdisconnect(log, data)
	local tname
	local takerole = true
	for _, option in pairs(data.data.options[1].options) do
		if option.name == "tname" then
			tname = option.value
		end
		if option.name == "takerole" then
			takerole = option.value
		end
	end
	local log = log:sub("appcommand_identmod_rdisconnect by duser $ for tname $ with takerole $", data.member.user.id, tname, takerole)
	local tuser, err = powder.fetch_user(tname)
	local ok, errcode, errbody
	if tuser == nil then
		log("failed to fetch user: $", err)
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = "Backend error, try again later.",
		})
	elseif not tuser then
		log("no such user")
		ok, errcode, errbody = discord_interaction_respond(data, {
			content = "No such user.",
		})
	else
		log("user found")
		local record = recheck_connection(log, db_rwhois(log, tuser.ID)[1])
		if record then
			log("found tuser $, disconnecting", tuser.ID)
			db_rdisconnect(log, tuser.ID)
			if takerole then
				take_role(log, record.duser)
			end
			ok, errcode, errbody = discord_interaction_respond(data, {
				content = "Done.",
			})
		else
			log("tuser $ not found", tuser.ID)
			ok, errcode, errbody = discord_interaction_respond(data, {
				content = subst("$ has not connected a Discord account.", tuser.Username),
			})
		end
	end
	if not ok then
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local function embed_response(message, tbl)
	tbl.message_reference = {
		message_id = message,
		fail_if_not_exists = false,
	}
	tbl.allowed_mentions = {
		replied_user = false,
		parse = util.make_array({}),
	}
	return tbl
end

local rate_limit_log = {}
local function rate_limit_embeds(duser)
	if not rate_limit_log[duser] then
		rate_limit_log[duser] = {}
	end
	local user_log = rate_limit_log[duser]
	local now = cqueues.monotime()
	while user_log[1] and user_log[1] < now - config.bot.embed_rate_denominator do
		table.remove(user_log, 1)
	end
	table.insert(user_log, now)
	return #user_log <= config.bot.embed_rate_numerator
end

local function do_save_embed(log, id, data, report_failure)
	local log = log:sub("do_save_embed by duser $ for id $ in dchannel $", data.author.id, id, data.channel_id)
	if not rate_limit_embeds(data.author.id) then
		log("request is in violation of rate limit")
		return
	end
	local save, err = powder.fetch_save(id)
	local ok, errcode, errbody
	if save == nil then
		log("failed to fetch save: $", err)
		ok, errcode, errbody = cli:create_channel_message(data.channel_id, embed_response(data.id, {
			content = "Backend error, try again later.",
		}))
	elseif not save then
		log("no such save")
		if not report_failure then
			return
		end
		ok, errcode, errbody = cli:create_channel_message(data.channel_id, embed_response(data.id, {
			content = "No such save.",
		}))
	else
		log("save found")
		ok, errcode, errbody = cli:create_channel_message(data.channel_id, embed_response(data.id, {
			embeds = {
				{
					type = "rich",
					title = save.Name,
					description = save.Description,
					color = secret_config.theme_color,
					timestamp = save.Date ~= 0 and util.iso8601(save.Date) or nil,
					image = {
						url = subst("http://static.powdertoy.co.uk/$.png", id),
					},
					author = {
						name = save.Username,
						url = subst("$/User.html?Name=$", secret_config.backend_base, save.Username),
					},
					footer = {
						text = subst("Score: $ - $ = $", save.ScoreUp, save.ScoreDown, save.Score),
					},
					url = subst("https://powdertoy.co.uk/Browse/View.html?ID=$", id),
				},
			},
		}))
	end
	if ok then
		rquser_events:push(ok.id, data.author.id)
	else
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local function do_user_embed(log, tname, data, report_failure)
	local log = log:sub("do_user_embed by duser $ for tname $ in dchannel $", data.author.id, tname, data.channel_id)
	if not rate_limit_embeds(data.author.id) then
		log("request is in violation of rate limit")
		return
	end
	local tuser, err = powder.fetch_user(tname)
	local ok, errcode, errbody
	if tuser == nil then
		log("failed to fetch user: $", err)
		ok, errcode, errbody = cli:create_channel_message(data.channel_id, embed_response(data.id, {
			content = "Backend error, try again later.",
		}))
	elseif not tuser then
		log("no such user")
		if not report_failure then
			return
		end
		ok, errcode, errbody = cli:create_channel_message(data.channel_id, embed_response(data.id, {
			content = "No such user.",
		}))
	elseif tuser.IsBanned then
		log("user is banned")
		if not report_failure then
			return
		end
		ok, errcode, errbody = cli:create_channel_message(data.channel_id, embed_response(data.id, {
			content = "User is banned.",
		}))
	else
		log("user found")
		local avatar = tuser.Avatar
		if avatar:find("^/") then
			avatar = secret_config.backend_base .. avatar
		else
			avatar = html_entities.decode(avatar)
		end
		local desc_info = {}
		table.insert(desc_info, subst("**ID:** $", tuser.ID))
		table.insert(desc_info, subst("**saves:** $", tuser.Saves.Count))
		table.insert(desc_info, subst("**average score:** $", tuser.Saves.AverageScore))
		table.insert(desc_info, subst("**highest score:** $", tuser.Saves.HighestScore))
		table.insert(desc_info, subst("**threads:** $", tuser.Forum.Topics))
		table.insert(desc_info, subst("**posts:** $", tuser.Forum.Replies))
		table.insert(desc_info, subst("**reputation:** $", tuser.Forum.Reputation))
		if tuser.RegisterTime then
			table.insert(desc_info, subst("**registered:** <t:$:d>", tuser.RegisterTime))
		else
			table.insert(desc_info, "**registered** a long time ago")
		end
		local record = recheck_connection(log, db_rwhois(log, tuser.ID)[1])
		if record and guild_members[record.duser] then
			table.insert(desc_info, subst("**known here as** <@$>", record.duser))
		end
		ok, errcode, errbody = cli:create_channel_message(data.channel_id, embed_response(data.id, {
			embeds = {
				{
					type = "rich",
					title = tuser.Username,
					description = table.concat(desc_info, "; ") .. ".",
					color = secret_config.theme_color,
					thumbnail = {
						url = avatar,
					},
					url = subst("https://powdertoy.co.uk/User.html?Name=$", tuser.Username),
				},
			},
		}))
	end
	if ok then
		rquser_events:push(ok.id, data.author.id)
	else
		log("failed to notify user: code $: $", errcode, errbody)
	end
end

local ok_to_respond = {
	[ discord.message.DEFAULT ] = true,
	[ discord.message.REPLY   ] = true,
}

local sender_events = make_event_log(config.bot.sender_max_log)
local function on_dispatch(_, dtype, data)
	cqueues.running():wrap(function()
		-- logger.dump(dtype)
		-- logger.dump(data)
		util.rethrow(function()
			if  dtype == "MESSAGE_CREATE"
			and ok_to_respond[data.type]
			and data.guild_id == secret_config.guild_id
			and not data.webhook_id
			and array_intersect(data.member.roles, secret_config.user_role_ids)
			and data.content then
				repeat
					local content_lower = data.content:lower()
					do -- id:# embeds
						local before, id = content_lower:match("^(.*)id:(%d+)")
						if id and (before == "" or before:find(" $")) then
							do_save_embed(log, id, data, true)
							break
						end
					end
					do -- user:# embeds
						local tname = content_lower:match("user:([A-Za-z0-9-_]+)")
						if tname then
							do_user_embed(log, tname, data, true)
							break
						end
					end
					do -- ~# embeds
						local id = content_lower:match("^~(%d+)")
						if id then
							do_save_embed(log, id, data, false)
							break
						end
					end
				until true
			end
			if  dtype == "MESSAGE_CREATE"
			and ok_to_respond[data.type]
			and data.guild_id == secret_config.guild_id
			and not data.webhook_id
			and data.content then
				sender_events:push(data.id, {
					user = {
						id = data.author.id,
						username = data.author.username,
						discriminator = data.author.discriminator,
						global_name = data.author.global_name,
					},
					channel = data.channel_id,
				})
			end
			if  dtype == "MESSAGE_DELETE"
			and data.guild_id == secret_config.guild_id then
				local sender = sender_events:get(data.id)
				local user = sender and discord.format_user(sender.user) or "?"
				local channel = sender and sender.channel or "?"
				log("message $ of $ got deleted in channel $", data.id, user, channel)
			end
			if dtype == "GUILD_CREATE" and data.id == secret_config.guild_id then
				local log = log:sub("listing members")
				for _, member in pairs(data.members) do
					log("found member duser $", member.user.id)
					guild_members[member.user.id] = true
				end
			end
			if dtype == "GUILD_MEMBER_ADD" and data.guild_id == secret_config.guild_id then
				guild_members[data.user.id] = true
				local log = log:sub("added member duser $", data.user.id)
				if not data.user.bot then
					local record = recheck_connection(log, db_whois(log, data.user.id)[1])
					if record and record.stale == 0 then
						give_role(log, data.user.id)
					else
						local ok, errcode, errbody = cli:create_channel_message(secret_config.verification_id, discord_response_data({
							content = subst("Hey there, <@$>. Read the pinned message in this channel, and use **/verify** or the button below to verify yourself.", data.user.id),
							components = {
								{
									type = discord.component.ACTION_ROW,
									components = {
										{
											type = discord.component.BUTTON,
											style = discord.component_button.PRIMARY,
											custom_id = command_custom_ids.verify,
											label = "Verify yourself",
										},
									},
								},
							},
						}))
						if not ok then
							log("failed to notify user: code $: $", errcode, errbody)
						end
					end
				end
			end
			if dtype == "GUILD_MEMBER_REMOVE" and data.guild_id == secret_config.guild_id then
				log:sub("removed member duser $", data.user.id)
				guild_members[data.user.id] = nil
			end
			if dtype == "INTERACTION_CREATE" and data.type == discord.interaction.MESSAGE_COMPONENT then
				if data.data.custom_id == command_custom_ids.verify then
					appcommand_ident(log, data)
				end
				if data.data.custom_id == command_custom_ids.setnick then
					appcommand_setnick(log, data)
				end
			end
			if dtype == "INTERACTION_CREATE" and data.type == discord.interaction.APPLICATION_COMMAND then
				if data.data.id == command_ids.ping then
					local log = log:sub("got a ping from $", discord.format_user(data.member.user))
					local ok, errcode, errbody = discord_interaction_respond(data, {
						content = "Pong!" .. (math.random() < 0.001 and " 🍌" or ""),
					})
					if not ok then
						log("failed to notify user: code $: $", errcode, errbody)
					end
				end
				if data.data.id == command_ids.verify then
					appcommand_ident(log, data)
				end
				if data.data.id == command_ids.setnick then
					appcommand_setnick(log, data)
				end
				if data.data.id == command_ids.whois then
					appcommand_whois(log, data)
				end
				if data.data.id == command_ids[WHOISCTX_NAME] then
					appcommand_whois(log, data)
				end
				if data.data.id == command_ids[GETRQUSER_NAME] then
					appcommand_getrquser(log, data)
				end
				if data.data.id == command_ids.rwhois then
					appcommand_rwhois(log, data)
				end
				if data.data.id == command_ids.identmod then
					if data.data.options[1].name == "connect" then
						appcommand_identmod_connect(log, data)
					end
					if data.data.options[1].name == "disconnect" then
						appcommand_identmod_disconnect(log, data)
					end
					if data.data.options[1].name == "rdisconnect" then
						appcommand_identmod_rdisconnect(log, data)
					end
					if data.data.options[1].name == "dwhois" then
						appcommand_identmod_dwhois(log, data)
					end
				end
			end
		end)
	end)
end

local function get_file_content(path)
	local handle = assert(io.open(path, "rb"))
	local data = handle:read("*a")
	handle:close()
	return data
end

local function serve_check_endpoint()
	local function render(good, message)
		local header, advice
		if good then
			header = "SUCCESS"
			advice = "You can close this window or tab now."
		else
			header = "ERROR"
			advice = "Contact a moderator on the server for help."
		end
		return "text/html", subst(get_file_content("check.html"), header, message, advice)
	end

	local function stream_response(log, path, query)
		if not path then
			log("no path specified")
			return 400, render(false, "Bad request, ask a moderator for help.")
		end
		if path == "/style.css" then
			return 200, "text/css", get_file_content("style.css")
		end
		if path == "/icon.png" then
			return 200, "image/png", get_file_content("icon.png")
		end
		if path == "/check" then
			local log = log:sub("check request")
			if not query then
				log("no query")
				return 400, render(false, "Bad request, ask a moderator for help.")
			end
			local query_args = {}
			for key, value in http_util.query_args(query) do
				if query_args[key] then
					log("duplicate query args")
					return 400, render(false, "Bad request, ask a moderator for help.")
				end
				query_args[key] = value
			end
			if not query_args.AppToken then
				log("missing AppToken")
				return 400, render(false, "Bad request, ask a moderator for help.")
			end
			if not query_args.PowderToken then
				log("missing PowderToken")
				return 400, render(false, "Bad request, ask a moderator for help.")
			end
			local payload, err = powder.token_payload(query_args.PowderToken)
			if not payload then
				log("bad PowderToken: $", err)
				return 400, render(false, "Bad request, ask a moderator for help.")
			end
			prune_iat_table(ident_tokens, config.bot.ident_token_max_age, function(token)
				invalidate_ident_token(log:sub("invalidating ident token for $: pruned", ident_tokens[token].user.id), token)
			end)
			if not ident_tokens[query_args.AppToken] then
				log("bad AppToken")
				return 401, render(false, "Link invalid or expired, try running /verify again.")
			end
			local info = ident_tokens[query_args.AppToken]
			invalidate_ident_token(log:sub("invalidating ident token: consumed"), query_args.AppToken)
			local function followup(status, tname)
				local log = log:sub("sending followup message")
				local ok, errcode, errbody
				if status == "failure" then
					ok, errcode, errbody = discord_interaction_followup(info.followup, {
						content = "An error occurred while trying verify you via this link. Contact " .. moderators_str .. " for help.",
					})
				elseif status == "too_new" then
					ok, errcode, errbody = discord_interaction_followup(info.followup, {
						content = "Your account is too new, try again later.",
					})
				else
					local format = "Account successfully connected, <@&$> role assigned."
					if status == "no_role" then
						format = "Account successfully connected, but the <@&$> role could not be assigned. Contact " .. moderators_str .. " for help."
					end
					local response_data = {
						content = subst(format, secret_config.managed_role_id),
						components = {
							{
								type = discord.component.ACTION_ROW,
								components = {
									{
										type = discord.component.BUTTON,
										style = discord.component_button.LINK,
										url = subst("$/User.html?Name=$", secret_config.backend_base, tname),
										label = subst("View $'s Powder Toy profile", tname),
									},
								},
							},
						},
					}
					local edname = get_effective_dname(info.user.id, info.user.global_name)
					if edname and status ~= "no_role" and tname ~= edname then
						response_data.content = response_data.content .. " Consider setting your Powder Toy name as your nickname."
						table.insert(response_data.components, {
							type = discord.component.ACTION_ROW,
							components = {
								{
									type = discord.component.BUTTON,
									style = discord.component_button.PRIMARY,
									custom_id = command_custom_ids.setnick,
									label = "Set your Powder Toy name as your nickname",
								},
							},
						})
					end
					ok, errcode, errbody = discord_interaction_followup(info.followup, response_data)
					if status == "ok" then
						local log = log:sub("sending welcome message")
						local ok, errcode, errbody = cli:create_channel_message(secret_config.welcome_id, discord_response_data({
							content = subst("Welcome <@$> to the server! Their Powder Toy account is $.", info.user.id, tname),
							url     = subst("$/User.html?Name=$", secret_config.backend_base, tname),
							label   = subst("View $'s Powder Toy profile", tname),
						}))
						if not ok then
							log("failed to notify user: code $: $", errcode, errbody)
						end
					end
				end
				if not ok then
					log("failed to notify user: code $: $", errcode, errbody)
				end
			end
			local status, err = powder.external_auth(query_args.PowderToken)
			if not status then
				log("failed to check PowderToken: $", err)
				followup("failure")
				return 503, render(false, "Authentication backend down, ask a moderator for help.")
			end
			if status ~= "OK" then
				log("bad PowderToken")
				followup("failure")
				return 401, render(false, "Authentication backend down, ask a moderator for help.")
			end
			local tuser, err = powder.fetch_user(payload.name)
			if tuser == false then
				log("no such user")
				followup("failure")
				return 503, render(false, "Authentication backend down, ask a moderator for help.")
			end
			if not tuser then
				log("failed to check PowderToken: $", err)
				followup("failure")
				return 503, render(false, "Authentication backend down, ask a moderator for help.")
			end
			if tuser.ID ~= tonumber(payload.sub) then
				log("tuser and payload sub mismatch: $ ~= $", tuser.ID, payload.sub)
				followup("failure")
				return 503, render(false, "Authentication backend down, ask a moderator for help.")
			end
			if tuser.Username ~= payload.name then
				log("tname and payload sub mismatch: $ ~= $", tuser.Username, payload.name)
				followup("failure")
				return 503, render(false, "Authentication backend down, ask a moderator for help.")
			end
			local register_time = tuser.RegisterTime and tonumber(tuser.RegisterTime)
			local now = os.time()
			if register_time and -- very old account if the property doesn't exist
			   register_time + config.bot.account_min_age > now then
				log("account too new")
				followup("too_new")
				return 401, render(false, subst("Account too new, try again in $ hours.", math.ceil((register_time + config.bot.account_min_age - now) / 3600)))
			end
			if info.tnameupdate then
				if info.tnameupdate ~= tuser.ID then
					log("tuser change from $ to $ on tname update", info.tnameupdate, tuser.ID)
					followup("failure")
					return 401, render(false, "Please use the Powder Toy account you first verified yourself with.")
				end
				db_tnameupdate(log, info.user.id, tuser.Username)
			else
				local ok, err = db_connect(log, info.user.id, tuser.ID, tuser.Username)
				if not ok then
					log("constraint violation")
					followup("failure") -- weird, shouldn't happen
					return 409, render(false, "Account already verified, no need to do it again.")
				end
			end
			local role_ok = give_role(log, info.user.id)
			log("success: connected duser $ with tuser $ aka $", info.user.id, tuser.ID, tuser.Username)
			followup(role_ok and "ok" or "no_role", tuser.Username)
			return 200, render(true, subst("$ is now connected with $.", info.user.global_name, tuser.Username))
		end
		log("not found: $", path)
		return 404, render(false, "Page not found, ask a moderator for help.")
	end

	local stream_counter = 0
	local server = http_server.listen({
		host = secret_config.http_listen_addr,
		port = secret_config.http_listen_port,
		onstream = function(_, stream)
			stream_counter = stream_counter + 1
			local log = log:sub("request $", stream_counter)
			local headers_in, err, errno = stream:get_headers()
			if not headers_in then
				log("failed to get headers: code $: $", errno, err)
			end
			local match = lpeg_patterns_uri.uri_reference:match(headers_in:get(":path"))
			local _, from = stream.connection:peername()
			if headers_in:get("x-forwarded-for") then
				from = headers_in:get("x-forwarded-for")
			end
			log("from $: $", from, (match and match.path and match.path:gsub("[^ -~]", function(cap)
				return ("\\x%02X"):format(cap:byte())
			end)))
			local status, content_type, body = stream_response(log, match and match.path, match and match.query)
			local headers_out = http_headers.new()
			headers_out:append(":status", tostring(status))
			headers_out:append("server", config.bot.http_server)
			headers_out:append("date", http_util.imf_date())
			headers_out:append("content-type", content_type)
			local deadline = cqueues.monotime() + config.bot.http_response_timeout
			local ok, err, errno = stream:write_headers(headers_out, false, deadline - cqueues.monotime())
			if not ok then
				log("write_headers failed: code $: $", errno, err)
				return
			end
			local ok, err, errno = stream:write_body_from_string(body, deadline - cqueues.monotime())
			if not ok then
				log("write_body_from_string failed: code $: $", errno, err)
				return
			end
		end,
	})

	assert(server:loop())
end

local queue = cqueues.new()

queue:wrap(function()
	cli = discord.client({
		on_dispatch          = on_dispatch,
		token                = secret_config.app_token,
		app_id               = secret_config.app_id,
		oauth_client_id      = secret_config.oauth_id,
		oauth_client_secret  = secret_config.oauth_secret,
		intents              = discord.intent.GUILDS          |
		                       discord.intent.GUILD_MEMBERS   |
		                       discord.intent.GUILD_PRESENCES |
		                       discord.intent.GUILD_MESSAGES  |
		                       discord.intent.MESSAGE_CONTENT,
		identify_browser     = config.bot.http_server,
		identify_device      = config.bot.http_server,
	})

	queue:wrap(function()
		util.rethrow(function()
			register_commands()
			cli:start()
		end)
	end)

	queue:wrap(function()
		util.rethrow(function()
			serve_check_endpoint()
		end)
	end)

	queue:wrap(function()
		util.rethrow(function()
			while true do
				cqueues.sleep(config.bot.random_recheck_interval)
				local log = log:sub("rechecking random user")
				recheck_connection(log, db_random_nonstale(log)[1])
			end
		end)
	end)
end)

local ok, err = queue:loop()
if not ok then
	queue:wrap(function()
		local data, errcode, errbody = cli:create_dm(secret_config.maintainer_id)
		if data then
			cli:create_channel_message(data.id, discord_response_data({
				content = "☠️",
			}))
		end
		error("forcing queue breakage")
	end)
	queue:loop()
end
assert(ok, err)
