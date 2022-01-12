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
	token_payload = token_payload,
	external_auth = external_auth,
}
