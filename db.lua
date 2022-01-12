local cqueues  = require("cqueues")
local lsqlite3 = require("lsqlite3")
local config   = require("config")

local handle_i = {}
local handle_m = { __index = handle_i }

function handle_i:exec(log, sql, ...)
	local stmt = self.db_:prepare(sql)
	if not stmt then
		error(self.db_:errmsg(), 2)
	end
	if stmt:bind_values(...) ~= lsqlite3.OK then
		error(self.db_:errmsg(), 2)
	end
	local result = {}
	local names = stmt:get_names()
	while true do
		local res = stmt:step()
		if res == lsqlite3.BUSY then
			log("db is busy, retrying in $ seconds", config.db.busy_delay)
			cqueues.sleep(config.db.busy_delay)
		elseif res == lsqlite3.DONE then
			break
		elseif res == lsqlite3.ROW then
			local row = {}
			local values = stmt:get_values()
			for i = 1, #names do
				row[names[i]] = values[i]
			end
			table.insert(result, row)
		elseif res == lsqlite3.CONSTRAINT then
			log("constraint violation, aborting")
			return nil, "constraint"
		else
			error(self.db_:errmsg(), 2)
		end
	end
	return result
end

local function handle(path)
	return setmetatable({
		db_ = assert(lsqlite3.open(path)),
	}, handle_m)
end

return {
	handle = handle,
}
