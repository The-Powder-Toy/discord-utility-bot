local http_cookie    = require("http.cookie")
local http_request   = require("http.request")
local http_websocket = require("http.websocket")
local http_util      = require("http.util")
local lunajson       = require("lunajson")
local basexx         = require("basexx")
local cqueues        = require("cqueues")
local cqueues_errno  = require("cqueues.errno")
local condition      = require("cqueues.condition")
local util           = require("util")

local subst = util.subst

local limits = {
	CUSTOM_ACTIVITY_MAX_LENGTH = 128,
}

local message = {
	DEFAULT = 0,
	REPLY   = 19,
}

local command = {
	CHAT_INPUT = 1,
	USER       = 2,
	MESSAGE    = 3,
}

local interaction = {
	PING                             = 1,
	APPLICATION_COMMAND              = 2,
	MESSAGE_COMPONENT                = 3,
	APPLICATION_COMMAND_AUTOCOMPLETE = 4,
}

local command_permission = {
	ROLE = 1,
	USER = 2,
}

local component = {
	ACTION_ROW  = 1,
	BUTTON      = 2,
	SELCET_MENU = 3,
}

local component_button = {
	PRIMARY   = 1,
	SECONDARY = 2,
	SUCCESS   = 3,
	DANGER    = 4,
	LINK      = 5,
}

local command_option = {
	SUB_COMMAND       =  1,
	SUB_COMMAND_GROUP =  2,
	STRING	          =  3,
	INTEGER	          =  4,
	BOOLEAN	          =  5,
	USER	          =  6,
	CHANNEL	          =  7,
	ROLE	          =  8,
	MENTIONABLE       =  9,
	NUMBER	          = 10,
}

local interaction_response_flag = {
	EPHEMERAL = 1 << 6,
}

local interaction_response = {
	CHANNEL_MESSAGE_WITH_SOURCE = 4,
}

local intent = {
	GUILDS                    = 1 <<  0,
	GUILD_MEMBERS             = 1 <<  1,
	GUILD_BANS                = 1 <<  2,
	GUILD_EMOJIS_AND_STICKERS = 1 <<  3,
	GUILD_INTEGRATIONS        = 1 <<  4,
	GUILD_WEBHOOKS            = 1 <<  5,
	GUILD_INVITES             = 1 <<  6,
	GUILD_VOICE_STATES        = 1 <<  7,
	GUILD_PRESENCES           = 1 <<  8,
	GUILD_MESSAGES            = 1 <<  9,
	GUILD_MESSAGE_REACTIONS   = 1 << 10,
	GUILD_MESSAGE_TYPING      = 1 << 11,
	DIRECT_MESSAGES           = 1 << 12,
	DIRECT_MESSAGE_REACTIONS  = 1 << 13,
	DIRECT_MESSAGE_TYPING     = 1 << 14,
	MESSAGE_CONTENT           = 1 << 15,
	GUILD_SCHEDULED_EVENTS    = 1 << 16,
}

local activity_type = {
	CUSTOM = 4,
}

math.randomseed(os.time())

local API_VERSION = 10
local PROTO_ERROR = {}

local function default_debug_print(cli, msg)
	print(("[discord client %s] %s"):format(tostring(cli), msg))
end

local aggregated_timeout_i = {}
local aggregated_timeout_m = { __index = aggregated_timeout_i }

function aggregated_timeout_i:add(timeout)
	self.value_ = self.value_ and math.min(self.value_, timeout) or timeout
end

function aggregated_timeout_i:get()
	return self.value_
end

local function aggregated_timeout()
	return setmetatable({}, aggregated_timeout_m)
end

local client_i = {}
local client_m = { __index = client_i }

function client_i:api_fetch_(method, path, data_in, extra)
	local req, err = http_request.new_from_uri(self.api_base_ .. "/v" .. API_VERSION .. path)
	if not req then
		return nil, err
	end
	req.version = 1.1 -- there is some bug in lua-http that breaks h2 + tls
	req.headers:upsert("authorization", extra and extra.authorization or ("Bot " .. self.token_))
	req.headers:upsert(":method", method)
	req.cookie_store = http_cookie.new_store()
	if data_in then
		if extra and extra.content_type == "urlencoded_form" then
			req.headers:upsert("content-type", "application/x-www-form-urlencoded")
			req:set_body(http_util.dict_to_query(data_in))
		else
			req.headers:upsert("content-type", "application/json")
			req:set_body(lunajson.encode(data_in, self.json_nullv_))
		end
	end
	local deadline = cqueues.monotime() + self.api_timeout_
	local headers, stream = req:go(deadline - cqueues.monotime())
	if not headers then
		return nil, stream
	end
	local body, err = stream:get_body_as_string(deadline - cqueues.monotime())
	if not body then
		return nil, err
	end
	local code = headers:get(":status")
	if not code:find("^2..$") then
		return nil, "non200", tonumber(code), body, headers
	end
	local ok, data_out = pcall(lunajson.decode, body)
	if not ok then
		data_out = body
	end
	return data_out, headers
end

function client_i:gateway_send_(data)
	local ok, err, errno = self.gateway_websocket_:send(lunajson.encode(data, self.json_nullv_), "text", self.gateway_send_timeout_)
	if not ok then
		self:gateway_die_("gateway send failed: errno $: $", errno, err)
	end
end

function client_i:gateway_arm_heartbeat_()
	if self.gateway_heartbeat_interval_ then
		self.gateway_send_ping_by_ = cqueues.monotime() + self.gateway_heartbeat_interval_
	end
end

function client_i:gateway_heartbeat_()
	self:gateway_send_({
		op = 1,
		d = self.gateway_last_seq_ or self.json_nullv_,
	})
end

function client_i:gateway_identify_()
	self:gateway_send_({
		op = 2,
		d = {
			token = "Bot " .. self.token_,
			properties = {
				[ "$os"      ] = self.identify_os_,
				[ "$browser" ] = self.identify_browser_,
				[ "$device"  ] = self.identify_device_,
			},
			intents = self.intents_,
		},
	})
end

function client_i:gateway_presence_()
	self:gateway_send_({
		op = 3,
		d = {
			since = self.json_nullv_,
			activities = self.effective_presence_ and {
				{
					name = "bagels",
					state = self.effective_presence_,
					type = activity_type.CUSTOM,
				},
			} or util.make_array({}),
			status = "online",
			afk = false,
		},
	})
end

function client_i:gateway_resume_()
	self:gateway_send_({
		op = 6,
		d = {
			token = "Bot " .. self.token_,
			session_id = self.gateway_session_id_,
			seq = self.gateway_last_seq_,
		},
	})
	self:gateway_arm_heartbeat_()
end

function client_i:gateway_handle_op_dispatch_0_(data)
	if math.type(data.s) ~= "integer" then
		self:gateway_die_("bad dispatch.s from gateway: $", data.s)
	end
	self.gateway_last_seq_ = data.s
	if type(data.t) ~= "string" then
		self:gateway_die_("bad dispatch.t from gateway: $", data.t)
	end
	if data.t == "READY" then
		self:debug_("gateway connection ready")
		self.gateway_session_id_ = data.d.session_id
	end
	self:on_dispatch_(data.t, data.d)
end

function client_i:gateway_handle_op_heartbeat_1_(data)
	self:gateway_heartbeat_()
	self:gateway_arm_heartbeat_()
end

function client_i:gateway_handle_op_reconnect_7_(data)
	self:gateway_die_("reconnect advised")
end

function client_i:gateway_handle_op_invalid_session_9_(data)
	if not data.d then
		self.gateway_session_id_ = nil
	end
	self:gateway_die_("session invalid")
end

function client_i:gateway_handle_op_hello_10_(data)
	self.gateway_want_hello_by_ = nil
	if type(data.d) ~= "table" then
		self:gateway_die_("bad dispatch.d from gateway: $", data.d)
	end
	if math.type(data.d.heartbeat_interval) ~= "integer" then
		self:gateway_die_("bad dispatch.d.heartbeat_interval from gateway: $", data.d.heartbeat_interval)
	end
	self.gateway_heartbeat_interval_ = data.d.heartbeat_interval / 1000
	self:gateway_arm_heartbeat_()
	if self.gateway_session_id_ then
		self:gateway_resume_()
	else
		self:gateway_identify_()
	end
end

function client_i:gateway_handle_op_heartbeat_ack_11_(data)
	self.gateway_want_pong_by_ = nil
end

function client_i:adjust_rate_limit_(bucket_name, remaining, reset_in)
	if not self.rate_limit_buckets_[bucket_name] then
		self.rate_limit_buckets_[bucket_name] = {}
	end
	local bucket = self.rate_limit_buckets_[bucket_name]
	bucket.remaining = remaining
	bucket.reset_at = cqueues.monotime() + reset_in
end

local global_rate_limit_m = {}

function global_rate_limit_m:__index(key)
	if key == "reset_at" then
		-- 50 per second, i.e. 25 per half a second. this way, any two adjacent
		-- half-seconds will have at most 50 requests, while with a
		-- straightforward 50 per second scheme, there might be more than 50
		-- requests in a non-ideally aligned second-long interval.
		local reset_at = math.ceil(cqueues.monotime() * 2) / 2
		if self.last_reset_at ~= reset_at then
			self.remaining = 25
			self.last_reset_at = reset_at
		end
		return reset_at
	end
end

local function global_rate_limit()
	return setmetatable({
		remaining = 0,
	}, global_rate_limit_m)
end

function client_i:prune_rate_limit_buckets_()
	local now = cqueues.monotime()
	local to_kill = {}
	for bucket_name, bucket in pairs(self.rate_limit_buckets_) do
		if bucket.reset_at < now then
			assert(bucket_name ~= "global")
			to_kill[bucket_name] = true
		end
	end
	for bucket_name in pairs(to_kill) do
		self.rate_limit_buckets_[bucket_name] = nil
	end
end

function client_i:rate_limit_take_from_bucket_(bucket_name)
	local bucket = self.rate_limit_buckets_[bucket_name]
	if bucket then
		if bucket.remaining == 0 then
			return nil, bucket.reset_at - cqueues.monotime()
		end
		bucket.remaining = bucket.remaining - 1
	end
	return true
end

function client_i:enforce_rate_limit_(endpoint, bucket_args)
	local debug_id = {}
	self:debug_("      [$] enforcing rate limit for endpoint $ with bucket args \"$\"", debug_id, endpoint, bucket_args)
	local queue = self.request_queue_by_endpoint_[endpoint]
	if queue then
		self:debug_("      [$] found existing queue, enqueuing", debug_id)
		local cond = condition.new()
		queue.items[queue.items_end] = cond
		self:debug_("      [$] enqueued at position $", debug_id, queue.items_end)
		queue.items_end = queue.items_end + 1
		self:debug_("      [$] waiting for previous request to finish", debug_id)
		cond:wait()
		self:debug_("      [$] done waiting", debug_id)
	end
	while true do
		self:prune_rate_limit_buckets_()
		self:debug_("      [$] attempting to execute request", debug_id)
		local ok, retry_in
		local bucket_primitive = self.rate_limit_bucket_primitives_[endpoint]
		if bucket_primitive then
			self:debug_("      [$] using bucket $", debug_id, bucket_primitive)
			ok, retry_in = self:rate_limit_take_from_bucket_(bucket_primitive .. bucket_args)
		else
			self:debug_("      [$] no relevant bucket found, proceeding", debug_id)
			ok = true
		end
		if ok then
			self:debug_("      [$] success, breaking out", debug_id)
			break
		end
		if not queue then
			self:debug_("      [$] creating queue", debug_id)
			queue = {
				items = {},
				items_begin = 1,
				items_end = 1,
			}
			self.request_queue_by_endpoint_[endpoint] = queue
		end
		self:debug_("      [$] sleeping for $ seconds", debug_id, retry_in)
		cqueues.sleep(retry_in)
		self:debug_("      [$] done sleeping", debug_id)
	end
	if queue then
		if queue.items_begin == queue.items_end then
			self.request_queue_by_endpoint_[endpoint] = nil
			self:debug_("      [$] queue was empty and collected", debug_id)
		else
			local cond = queue.items[queue.items_begin]
			queue.items[queue.items_begin] = nil
			self:debug_("      [$] dequeued from position $", debug_id, queue.items_begin)
			queue.items_begin = queue.items_begin + 1
			cond:signal()
			self:debug_("      [$] next request in queue signalled", debug_id)
		end
	end
end

function client_i:patient_api_fetch_(endpoint, ...)
	local vararg_offset = 1
	local vararg = { ... }
	local method, path = assert(endpoint:match("^([^ ]+) (.+)$"))
	local bucket_args = ""
	path = path:gsub("[#$]", function(cap)
		local replacement = tostring(vararg[vararg_offset])
		vararg_offset = vararg_offset + 1
		if cap == "#" then
			bucket_args = bucket_args .. " " .. replacement
		end
		return replacement
	end)
	self:enforce_rate_limit_("", "") -- global 50-per-second limit
	self:enforce_rate_limit_(endpoint, bucket_args)
	local data, headers
	while true do
		local err, errcode, errbody, errheaders
		data, err, errcode, errbody, errheaders = self:api_fetch_(method, path, select(vararg_offset, ...))
		headers = data and err or errheaders
		if headers then
			if headers:get("x-ratelimit-bucket") then
				local bucket_primitive = "bucket " .. headers:get("x-ratelimit-bucket")
				local remaining = assert(tonumber(headers:get("x-ratelimit-remaining")))
				local reset_in  = assert(tonumber(headers:get("x-ratelimit-reset-after")))
				self.rate_limit_bucket_primitives_[endpoint] = bucket_primitive
				self:adjust_rate_limit_(bucket_primitive .. bucket_args, remaining, reset_in)
			else
				self.rate_limit_bucket_primitives_[endpoint] = nil
			end
		else
			self:debug_("  no headers?...")
		end
		if not data then
			local retry_in = self.api_retry_delay_
			if err == "non200" then
				if errcode == 429 and headers then
					-- shouldn't be possible, but let's just wait however much discord wants us to wait
					retry_in = assert(tonumber(headers:get("retry-after")))
					-- local errdata = lunajson.decode(errbody)
					retry_in = errdata.retry_after
					local info = {}
					table.insert(info, subst("endpoint = $", endpoint))
					table.insert(info, subst("x-ratelimit-limit = $", headers:get("x-ratelimit-limit")))
					table.insert(info, subst("x-ratelimit-remaining = $", headers:get("x-ratelimit-remaining")))
					table.insert(info, subst("x-ratelimit-reset = $", headers:get("x-ratelimit-reset")))
					table.insert(info, subst("x-ratelimit-reset-after = $", headers:get("x-ratelimit-reset-after")))
					table.insert(info, subst("x-ratelimit-bucket = $", headers:get("x-ratelimit-bucket")))
					table.insert(info, subst("x-ratelimit-global = $", headers:get("x-ratelimit-global")))
					table.insert(info, subst("x-ratelimit-scope = $", headers:get("x-ratelimit-scope")))
					-- table.insert(info, subst("message = $", errdata.message))
					self:debug_("  rate limit violation: $", table.concat(info, ", "))
				else
					return nil, errcode, errbody, errheaders
				end
			end
			self:debug_("  retrying in $ seconds", retry_in)
			cqueues.sleep(retry_in)
		end
		if data then
			break
		end
	end
	return data, headers
end

function client_i:gateway_get_endpoint_()
	if not self.gateway_endpoint_ or cqueues.monotime() > self.gateway_endpoint_from_ + self.gateway_endpoint_max_age_ then
		local data, errcode, errbody = self:patient_api_fetch_("GET /gateway")
		if not data then
			self:debug_("  failed: status $: $", errcode, errbody)
			error(PROTO_ERROR)
		end
		if type(data.url) ~= "string" then
			self:debug_("  failed: bad url field")
			error(PROTO_ERROR)
		end
		self.gateway_endpoint_ = data.url
		self.gateway_endpoint_from_ = cqueues.monotime()
	end
	return self.gateway_endpoint_
end

function client_i:gateway_die_(...)
	self:debug_(...)
	self.gateway_websocket_:close(1002, "protocol error", self.gateway_send_timeout_)
	self.gateway_websocket_ = nil
	self.gateway_websocket_pollable_ = nil
	self.gateway_want_hello_by_ = nil
	self.gateway_want_pong_by_ = nil
	self.gateway_send_ping_by_ = nil
	error(PROTO_ERROR)
end

local gateway_op_handlers = {}
for key, value in pairs(client_i) do
	local op = key:match("^gateway_handle_op_.*_(%d+)_$")
	if op then
		gateway_op_handlers[tonumber(op)] = value
	end
end
function client_i:gateway_handle_payload_(payload)
	local ok, data = pcall(lunajson.decode, payload)
	if not ok then
		self:gateway_die_("bad json from gateway: $ in response to payload $", data, payload)
	end
	if math.type(data.op) ~= "integer" or not gateway_op_handlers[data.op] then
		self:gateway_die_("bad op from gateway: $", data.op)
	end
	gateway_op_handlers[data.op](self, data)
end

function client_i:gateway_talk_once_()
	self.gateway_want_hello_by_ = cqueues.monotime() + self.gateway_connect_timeout_
	local err
	self:debug_("getting gateway endpoint")
	local endpoint = self:gateway_get_endpoint_()
	self:debug_("  is $", endpoint)
	self.gateway_websocket_, err = http_websocket.new_from_uri(endpoint .. "?v=" .. API_VERSION .. "&encoding=json")
	if not self.gateway_websocket_ then
		self:gateway_die_("failed to connect to gateway: $", err)
	end
	local ok, err, errno = self.gateway_websocket_:connect(self.gateway_connect_timeout_)
	if not ok then
		self:gateway_die_("failed to connect to gateway: errno $: $", errno, err)
	end
	self.gateway_websocket_pollable_ = { pollfd = self.gateway_websocket_.socket:pollfd(), events = "r" }
	while true do
		local timeout = aggregated_timeout()
		if self.gateway_want_hello_by_ then
			timeout:add(self.gateway_want_hello_by_ - cqueues.monotime())
		end
		if self.gateway_want_pong_by_ then
			timeout:add(self.gateway_want_pong_by_ - cqueues.monotime())
		end
		if self.gateway_send_ping_by_ then
			timeout:add(self.gateway_send_ping_by_ - cqueues.monotime())
		end
		if self.gateway_websocket_.socket:pending() == 0 then
			cqueues.poll(self.gateway_websocket_pollable_, self.status_cond_, timeout:get())
		end
		local payload, err, errno = self.gateway_websocket_:receive(0)
		if not payload and errno ~= cqueues_errno.ETIMEDOUT then
			self:gateway_die_("gateway receive failed: errno $: $", errno, err)
		end
		if self.status_ ~= "running" then
			self:debug_("exiting gateway_talk_once_ due to stop")
			break
		end
		if payload then
			self:gateway_handle_payload_(payload)
		end
		if self.gateway_want_hello_by_ and cqueues.monotime() >= self.gateway_want_hello_by_ then
			self:gateway_die_("gateway hello timeout")
		end
		if self.gateway_want_pong_by_ and cqueues.monotime() >= self.gateway_want_pong_by_ then
			self:gateway_die_("gateway heartbeat ack timeout")
		end
		if self.gateway_send_ping_by_ and cqueues.monotime() >= self.gateway_send_ping_by_ then
			self.gateway_send_ping_by_ = nil
			self:gateway_heartbeat_()
			self:gateway_arm_heartbeat_()
			self.gateway_want_pong_by_ = cqueues.monotime() + self.gateway_heartbeat_ack_timeout_
		end
		if self.gateway_session_id_ then
			if self.effective_presence_ ~= self.requested_presence_ then
				self.effective_presence_ = self.requested_presence_
				self:gateway_presence_()
			end
		end
	end
	self.gateway_websocket_:close(1000, "bye", self.gateway_send_timeout_)
	self.gateway_websocket_ = nil
	self.gateway_websocket_pollable_ = nil
end

function client_i:gateway_talk_()
	while true do
		local proto_error = false
		local ok, err = xpcall(function()
			self:gateway_talk_once_()
		end, function(err)
			if err == PROTO_ERROR then
				proto_error = true
				return
			end
			self:debug_(err)
			self:debug_(debug.traceback())
			return err
		end)
		if not ok and not proto_error then
			error(err, 0)
		end
		if self.status_ ~= "running" then
			self:debug_("exiting gateway_talk_ due to stop")
			return
		end
		self:debug_("  reconnecting in $ seconds", self.gateway_retry_delay_)
		cqueues.sleep(self.gateway_retry_delay_)
	end
end

function client_i:stop()
	assert(self.status_ == "running" or self.status_ == "stopping" or self.status_ == "dead", "not running")
	if self.status_ == "running" then
		self.status_ = "stopping"
		self.status_cond_:signal()
	end
end

function client_i:presence(presence)
	assert(self.status_ == "running", "not running")
	assert(type(presence) == "string" or presence == nil)
	self.requested_presence_ = presence
	self.status_cond_:signal()
end

function client_i:start()
	assert(self.status_ == "ready")
	self.status_ = "running"
	cqueues.running():wrap(function()
		util.rethrow(function()
			self:gateway_talk_()
		end)
	end)
end

function client_i:debug_(...)
	self:debug_print_(subst(...))
end

function client_i:create_channel_message(channel, data)
	return self:patient_api_fetch_("POST /channels/#/messages", channel, data)
end

function client_i:create_interaction_response(interaction, token, data)
	return self:patient_api_fetch_("POST /interactions/$/$/callback", interaction, token, data)
end

function client_i:create_followup_message(token, data)
	return self:patient_api_fetch_("POST /webhooks/$/$", self.app_id_, token, data)
end

function client_i:set_application_commands(guild, data)
	return self:patient_api_fetch_("PUT /applications/$/guilds/#/commands", self.app_id_, guild, data)
end

function client_i:assign_user_role(guild, user, role)
	return self:patient_api_fetch_("PUT /guilds/#/members/$/roles/$", guild, user, role)
end

function client_i:unassign_user_role(guild, user, role)
	return self:patient_api_fetch_("DELETE /guilds/#/members/$/roles/$", guild, user, role)
end

function client_i:get_user_nick(guild, user)
	local data, errcode, errbody, errheaders = self:patient_api_fetch_("GET /guilds/#/members/$", guild, user)
	if not data then
		return nil, errcode, errbody, errheaders
	end
	return data.nick or false
end

function client_i:get_user_roles(guild, user)
	local data, errcode, errbody, errheaders = self:patient_api_fetch_("GET /guilds/#/members/$", guild, user)
	if not data then
		return nil, errcode, errbody, errheaders
	end
	return data.roles
end

function client_i:set_user_nick(guild, user, nick)
	return self:patient_api_fetch_("PATCH /guilds/#/members/$", guild, user, {
		nick = nick,
	})
end

function client_i:create_dm(user)
	return self:patient_api_fetch_("POST /users/@me/channels", {
		recipient_id = user,
	})
end

function client_i:get_bearer_token_(scopes)
	table.sort(scopes)
	local key = table.concat(scopes, " ")
	local now = cqueues.monotime()
	if not self.bearer_tokens_[key] or self.bearer_tokens_[key].expires_at < now then
		local data, errcode, errbody = self:patient_api_fetch_("POST /oauth2/token", {
			grant_type = "client_credentials",
			scope = key,
		}, {
			authorization = "Basic " .. basexx.to_base64(subst("$:$", self.oauth_client_id_, self.oauth_client_secret_)),
			content_type = "urlencoded_form",
		})
		if not data then
			error(subst("error: code $: $", errcode, errbody))
		end
		self.bearer_tokens_[key] = {
			token = data.access_token,
			expires_at = now + data.expires_in,
		}
	end
	return self.bearer_tokens_[key].token
end

local function client(params)
	return setmetatable({
		soft_proto_errors_             = params.soft_proto_errors,
		debug_print_                   = params.debug_print                   or default_debug_print,
		json_nullv_                    = params.json_nullv                    or {},
		api_base_                      = params.api_base                      or "https://discord.com/api",
		api_connect_timeout_           = params.api_connect_timeout           or 5,
		api_retry_delay_               = params.api_retry_delay               or 5,
		rate_limit_bucket_max_age_     = params.rate_limit_bucket_max_age     or 300,
		gateway_retry_delay_           = params.gateway_retry_delay           or 5,
		gateway_connect_timeout_       = params.gateway_connect_timeout       or 5,
		gateway_heartbeat_ack_timeout_ = params.gateway_heartbeat_ack_timeout or 5,
		gateway_send_timeout_          = params.gateway_send_timeout          or 5,
		gateway_endpoint_max_age_      = params.gateway_endpoint_max_age      or 300,
		api_timeout_                   = params.api_timeout                   or 5,
		oauth_client_id_               = params.oauth_client_id               or 5,
		oauth_client_secret_           = params.oauth_client_secret           or 5,
		status_                        = "ready",
		status_cond_                   = condition.new(),
		gateway_endpoint_              = false,
		gateway_endpoint_from_         = false,
		intents_                       = params.intents,
		on_dispatch_                   = params.on_dispatch,
		token_                         = params.token,
		app_id_                        = params.app_id,
		identify_os_                   = params.identify_os or "linux",
		identify_browser_              = params.identify_browser or "bagels",
		identify_device_               = params.identify_device or "bagels",
		rate_limit_bucket_primitives_  = { [ "" ] = "global" },
		rate_limit_buckets_            = { [ "global" ] = global_rate_limit() },
		request_queue_by_endpoint_     = {},
		bearer_tokens_                 = {},
	}, client_m)
end

local function format_user(user)
	if user.global_name then
		return subst("$ aka $ aka $", user.id, user.username, user.global_name)
	end
	return subst("$ aka $#$", user.id, user.username, user.discriminator)
end

local function normalize_iso8601(str)
	local year, month, day, hour, min, sec = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
	if not year then
		year, month, day, hour, min, sec = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.%d+%+00:00")
	end
	if year then
		return ("%04d-%02d-%02dT%02d:%02d:%02dZ"):format(year, month, day, hour, min, sec)
	end
end

return {
	client                    = client,
	limits                    = limits,
	intent                    = intent,
	interaction_response      = interaction_response,
	interaction_response_flag = interaction_response_flag,
	command_option            = command_option,
	component                 = component,
	component_button          = component_button,
	command_permission        = command_permission,
	command                   = command,
	interaction               = interaction,
	message                   = message,
	subst                     = subst,
	format_user               = format_user,
	normalize_iso8601         = normalize_iso8601,
}
