local function iso8601(unix)
	return os.date("!%FT%TZ", unix)
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

return {
	iso8601    = iso8601,
	rethrow    = rethrow,
	subst      = subst,
	make_array = make_array,
}
