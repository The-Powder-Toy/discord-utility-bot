local subst = require("util").subst

local logger_i = {}
local logger_m = { __index = logger_i }

function logger_m:__call(...)
	self.func_(subst("[$] $$", ("% 8i"):format(self.fragment_), self.prefix_, subst(...)))
end

function logger_i:sub(thing, ...)
	local next_fragment = self.next_fragment_()
	if thing then
		self.func_(subst("[$] $$ => $", ("% 8i"):format(self.fragment_), self.prefix_, subst(thing, ...), next_fragment))
	end
	local level = self.level_ + 1
	return setmetatable({
		func_ = self.func_,
		level_ = level,
		prefix_ = ("  "):rep(level),
		next_fragment_ = self.next_fragment_,
		fragment_ = next_fragment,
	}, logger_m)
end

local function new(func)
	local fragment = 0
	local function next_fragment()
		fragment = fragment + 1
		return fragment
	end
	return setmetatable({
		func_ = func,
		level_ = 0,
		prefix_ = "",
		next_fragment_ = next_fragment,
		fragment_ = next_fragment(),
	}, logger_m)
end

local function dump(thing, level)
	level = level or 0
	if type(thing) == "table" then
		print("{")
		for key, value in pairs(thing) do
			io.stdout:write(("  "):rep(level + 1) .. key .. " => ")
			dump(value, level + 1)
		end
		print(("  "):rep(level) .. "}")
	elseif type(thing) == "string" then
		print(("%q"):format(thing))
	else
		print(tostring(thing))
	end
end

return {
	new = new,
	dump = dump,
}
