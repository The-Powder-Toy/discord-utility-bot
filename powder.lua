local cqueues           = require("cqueues")
local secret_config     = require("secret_config")
local http_cookie       = require("http.cookie")
local http_request      = require("http.request")
local lunajson          = require("lunajson")
local subst             = require("util").subst
local basexx            = require("basexx")
local config            = require("config")

local function valid_user(tname)
	if #tname == 0 or #tname > 32 or tname:find("[^a-zA-Z0-9_-]") then
		return false
	end
	return true
end

local function fetch_user(tname)
	if not valid_user(tname) then
		return false
	end
	local req, err = http_request.new_from_uri(subst("$/User.json?Name=$", secret_config.backend_base, tname))
	if not req then
		return nil, err
	end
	req.headers:upsert("user-agent", config.bot.http_server)
	req.version = 1.1
	req.cookie_store = http_cookie.new_store()
	local deadline = cqueues.monotime() + config.powder.fetch_user_timeout
	local headers, stream = req:go(deadline - cqueues.monotime())
	if not headers then
		return nil, stream
	end
	local code = headers:get(":status")
	if code ~= "200" then
		return nil, "status code " .. code
	end
	local body, err = stream:get_body_as_string(deadline - cqueues.monotime())
	if not body then
		return nil, err
	end
	if body == "Error: 404" then
		return false
	end
	local ok, json = pcall(lunajson.decode, body)
	if not ok then
		return nil, json
	end
	if not (type(json) == "table" and
	        type(json.User) == "table" and
	        type(json.User.ID) == "number" and
	        type(json.User.Username) == "string") then
		return nil, "invalid response from backend"
	end
	return json.User
end

local function valid_save(id)
	if #id == 0 or #id > 9 or id:find("[^%d]") then
		return false
	end
	return true
end

local function fetch_save(id)
	if not valid_save(id) then
		return false
	end
	local req, err = http_request.new_from_uri(subst("$/Browse/View.json?ID=$", secret_config.backend_base, id))
	if not req then
		return nil, err
	end
	req.headers:upsert("user-agent", config.bot.http_server)
	req.version = 1.1
	req.cookie_store = http_cookie.new_store()
	local deadline = cqueues.monotime() + config.powder.fetch_save_timeout
	local headers, stream = req:go(deadline - cqueues.monotime())
	if not headers then
		return nil, stream
	end
	local code = headers:get(":status")
	if code ~= "200" then
		return nil, "status code " .. code
	end
	local body, err = stream:get_body_as_string(deadline - cqueues.monotime())
	if not body then
		return nil, err
	end
	local ok, json = pcall(lunajson.decode, body)
	if not ok then
		return nil, json
	end
	if type(json) == "table" and json.Username == "FourOhFour" then
		return false
	end
	if not (type(json) == "table" and
	        type(json.Name) == "string" and
	        type(json.Description) == "string" and
	        type(json.Username) == "string" and
	        type(json.Score) == "number" and
	        type(json.Date) == "number") then
		return nil, "invalid response from backend"
	end
	return json
end

local function get_motd_regions(motd)
	local regions = {}
	local fragments = ""
	local it = 1
	while it <= #motd do
		local function find(it, ch)
			while it <= #motd do
				if motd:sub(it, it) == ch then
					break
				end
				it = it + 1
			end
			return it
		end
		local begin_region_it = find(it, "{")
		local begin_data_it = find(begin_region_it, ":")
		local begin_text_it = find(begin_data_it, "|")
		local end_region_it = find(begin_text_it, "}")
		if end_region_it > #motd then
			break
		end
		local action = motd:sub(begin_region_it + 1, begin_data_it - 1)
		local data = motd:sub(begin_data_it + 1, begin_text_it - 1)
		local text = motd:sub(begin_text_it + 1, end_region_it - 1)
		fragments = fragments .. motd:sub(it, begin_region_it - 1)
		local good = false
		if action == "a" and #data > 0 and #text > 0 then
			local region = {}
			local old_size = #fragments
			fragments = fragments .. text
			region.size = #fragments - old_size
			region.pos = old_size + 1
			region.action = "link"
			region.url = data
			table.insert(regions, region)
			good = true
		end
		if not good then
			fragments = fragments .. motd:sub(begin_region_it, end_region_it)
		end
		it = end_region_it + 1
	end
	fragments = fragments .. motd:sub(it)
	return fragments, regions
end

local function fetch_motd()
	local req, err = http_request.new_from_uri(subst("$/Startup.json", secret_config.backend_base))
	if not req then
		return nil, err
	end
	req.headers:upsert("user-agent", config.bot.http_server)
	req.version = 1.1
	req.cookie_store = http_cookie.new_store()
	local deadline = cqueues.monotime() + config.powder.fetch_motd_timeout
	local headers, stream = req:go(deadline - cqueues.monotime())
	if not headers then
		return nil, stream
	end
	local code = headers:get(":status")
	if code ~= "200" then
		return nil, "status code " .. code
	end
	local body, err = stream:get_body_as_string(deadline - cqueues.monotime())
	if not body then
		return nil, err
	end
	local ok, json = pcall(lunajson.decode, body)
	if not ok then
		return nil, json
	end
	if not (type(json) == "table" and
	        type(json.MessageOfTheDay) == "string") then
		return nil, "invalid response from backend"
	end
	local text, regions = get_motd_regions(json.MessageOfTheDay)
	local function remove(pat)
		text = text:gsub(pat:gsub("%.", utf8.charpattern), "")
	end
	remove("\b.")
	remove("\14")
	remove("\15...")
	return text, regions
end

local function token_payload(token)
	local payload = token:match("^[^%.]+%.([^%.]+)%.[^%.]+$")
	if not payload then
		return nil, "no payload"
	end
	local unb64 = basexx.from_url64(payload)
	if not unb64 then
		return nil, "bad base64"
	end
	local ok, json = pcall(lunajson.decode, unb64)
	if not ok then
		return nil, "bad json: " .. json
	end
	if type(json) ~= "table" then
		return nil, "bad payload document"
	end
	if type(json.sub) ~= "string" or json.sub:find("[^0-9]") then
		return nil, "bad payload subject"
	end
	if json.aud ~= secret_config.backend_audience then
		return nil, "bad payload audience"
	end
	return json
end

local function external_auth(powder_token)
	local req, err = http_request.new_from_uri(subst("$/ExternalAuth.api?Action=Check&MaxAge=$&Token=$", secret_config.backend_base, config.powder.powder_token_max_age, powder_token))
	if not req then
		return nil, "failed to create request: " .. err
	end
	req.headers:upsert("user-agent", config.bot.http_server)
	req.version = 1.1
	req.cookie_store = http_cookie.new_store()
	local deadline = cqueues.monotime() + config.powder.externalauth_timeout
	local headers, stream = req:go(deadline - cqueues.monotime())
	if not headers then
		return nil, "failed to submit request: " .. stream
	end
	local code = headers:get(":status")
	if code ~= "200" then
		return nil, "status code " .. code
	end
	local body, err = stream:get_body_as_string(deadline - cqueues.monotime())
	if not body then
		return nil, "failed to get response body: " .. err
	end
	local ok, json = pcall(lunajson.decode, body)
	if not ok or type(json) ~= "table" then
		return nil, "bad json: " .. json .. " with body " .. body
	end
	return json.Status
end

return {
	valid_user    = valid_user,
	fetch_user    = fetch_user,
	valid_save    = valid_save,
	fetch_save    = fetch_save,
	fetch_motd    = fetch_motd,
	token_payload = token_payload,
	external_auth = external_auth,
}
