local function copyDeep<T>(t: T): T
	if typeof(t) ~= "table" then
		return t
	end

	local new = table.clone(t :: any)

	for key, value in t :: any do
		if typeof(value) == "table" then
			new[key] = copyDeep(value)
		elseif typeof(value) == "buffer" then
			local copy = buffer.create(buffer.len(value))
			new[key] = buffer.copy(value, 0, copy)
		end
	end

	return new :: any
end

local function mergeDeep<T>(...: any): T
	local result = {}

	for tIndex = 1, select("#", ...) do
		local t = select(tIndex, ...)

		if typeof(t) ~= "table" then
			continue
		end

		for key, value in t do
			if typeof(value) == "table" then
				if result[key] == nil or typeof(result[key]) ~= "table" then
					result[key] = copyDeep(value)
				else
					result[key] = mergeDeep(result[key], value)
				end
			elseif typeof(value) == "buffer" then
				local copy = buffer.create(buffer.len(value))
				result[key] = buffer.copy(value, 0, copy)
			else
				result[key] = value
			end
		end
	end

	return result :: any
end

local function mergeShallow<T>(...: any): T
	local result = {}

	for tIndex = 1, select("#", ...) do
		local t = select(tIndex, ...)

		if typeof(t) ~= "table" then
			continue
		end

		for key, value in t do
			result[key] = value
		end
	end

	return result :: any
end

local function map<T, U>(array: { T }, mapper: (value: T, index: number, array: { T }) -> U?): { U }
	local mapped = {}

	for index, value in array do
		local mappedValue = mapper(value, index, array)

		if mappedValue ~= nil then
			table.insert(mapped, mappedValue)
		end
	end

	return mapped
end

local function equalsDeep(a: { [any]: any }, b: { [any]: any }): boolean
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return a == b
	end

	for key, value in a do
		if not equalsDeep(value, b[key]) then
			return false
		end
	end

	for key, value in b do
		if not equalsDeep(value, a[key]) then
			return false
		end
	end

	return true
end

local function freezeDeep<T>(t: T): ()
	if typeof(t) ~= "table" then
		return
	end

	if table.isfrozen(t) == false then
		table.freeze(t)
	end

	for _, value in t :: any do
		if typeof(value) == "table" then
			freezeDeep(value)
		end
	end
end

return {
	copyDeep = copyDeep,
	mergeDeep = mergeDeep,
	mergeShallow = mergeShallow,
	equalsDeep = equalsDeep,
	freezeDeep = freezeDeep,
	map = map,
}
