local function to_iso8601(unix)
	return os.date("!%FT%TZ", unix)
end

local function from_iso8601(str)
	local function from_str(str)
		local year, month, day, hour, min, sec = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
		return year and os.time({
			year  = tonumber(year),
			month = tonumber(month),
			day   = tonumber(day),
			hour  = tonumber(hour),
			min   = tonumber(min),
			sec   = tonumber(sec),
			isdst = false,
		})
	end
	local time = str and from_str(str)
	if time then
		return time - (from_str(os.date("!%FT%TZ", 0)) - from_str(os.date("%FT%TZ", 0)))
	end
end

local function rethrow(func)
	assert(xpcall(func, function(err)
		print(err)
		print(debug.traceback())
		return err
	end))
end

local function subst(fmt, ...)
	local args = { ... }
	local counter = 0
	return (fmt:gsub("%$", function(cap)
		counter = counter + 1
		return tostring(args[counter])
	end))
end

local function make_array(tbl)
	tbl[0] = #tbl
	return tbl
end

local function split(str, delim)
	local tbl = {}
	local cursor = 1
	while true do
		local first, last = str:find(delim, cursor, true)
		if not first then
			break
		end
		table.insert(tbl, str:sub(cursor, first - 1))
		cursor = last + 1
	end
	table.insert(tbl, str:sub(cursor))
	return tbl
end

return {
	to_iso8601   = to_iso8601,
	from_iso8601 = from_iso8601,
	rethrow      = rethrow,
	subst        = subst,
	make_array   = make_array,
	split        = split,
}
