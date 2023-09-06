local history_i = {}
local history_m = { __index = history_i }

function history_i:push(key, data, weight)
	weight = weight or 1
	self.items_[self.head_] = {
		key    = key,
		data   = data,
		weight = weight,
	}
	self.indices_[key] = self.head_
	self.head_ = self.head_ + 1
	self.usage_ = self.usage_ + weight
	while self.usage_ > self.max_usage_ do
		local item = self.items_[self.tail_]
		if self.indices_[item.key] == self.tail_ then
			self.indices_[item.key] = nil
		end
		self.items_[self.tail_] = nil
		self.tail_ = self.tail_ + 1
		self.usage_ = self.usage_ - item.weight
	end
end

function history_i:rename(old_key, new_key)
	local index = self.indices_[old_key]
	if index then
		local item = self.items_[index]
		self.indices_[old_key] = nil
		self.indices_[new_key] = index
		item.key = new_key
	end
end

function history_i:all()
	local curr = self.tail_
	return function()
		if curr == self.head_ then
			return
		end
		local item = self.items_[curr]
		curr = curr + 1
		return item.key, item.data, item.weight
	end
end

function history_i:get(key)
	return self.indices_[key] and self.items_[self.indices_[key]].data
end

local function history(max_usage)
	return setmetatable({
		max_usage_ = max_usage,
		usage_ = 0,
		head_ = 1,
		tail_ = 1,
		items_ = {},
		indices_ = {},
	}, history_m)
end

return {
	history = history,
}
