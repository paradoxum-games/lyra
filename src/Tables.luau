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

-- Performs a deep reconciliation of a target table with a source table,
-- applying Copy-On-Write (COW) semantics for the target.
-- The function assumes 'target' and 'source' are non-nil tables.
--
-- Behavior:
-- - Values from 'source' overwrite corresponding values in 'target'.
--   If a value in 'source' is a table, its reference is used directly.
-- - Keys present in 'source' but not in 'target' are added to the result,
--   using 'source's values/references.
-- - Keys present in 'target' but not in 'source' (omitted) are removed from the result.
-- - If 'source' is an empty table, the result will be an empty table, unless 'target'
--   was already empty, in which case 'target' is returned.
local function reconcileDeep<T>(target: T, source: T): T
	-- 1. Handle empty source table:
	-- If 'source' is empty, it dictates that the resulting state should have no keys
	if next(source :: any) == nil then
		if next(target :: any) == nil then
			-- Both 'target' and 'source' are empty. 'target' is unchanged.
			return target
		else
			-- 'target' has keys, but 'source' (empty) dictates they should be removed.
			-- Return source.
			return source
		end
	end

	-- At this point, 'source' is guaranteed to be non-empty.
	-- 'target' can be empty or non-empty.

	-- 2. Main reconciliation logic:
	-- Start by assuming no changes; 'result' points to the original 'target'.
	local result: T = target
	-- Tracks if 'result' has been shallow copied from 'target' at the current level.
	local hasBeenCopied = false

	-- Pass 1: Iterate over 'source' keys to update or add to 'target'.
	-- This pass applies 'source's state onto 'target'.
	for key, sourceValue in source :: any do
		local targetValue = (target :: any)[key]

		if typeof(sourceValue) == "table" then
			local sourceTableValue = sourceValue :: T

			if typeof(targetValue) == "table" then
				local targetTableValue = targetValue :: T
				-- Recursively reconcile the sub-tables.
				local reconciledSubTable = reconcileDeep(targetTableValue, sourceTableValue)

				-- If the recursive call returned a new table instance for the sub-table,
				-- it means a change occurred at a deeper level.
				if reconciledSubTable ~= targetTableValue then
					if not hasBeenCopied then
						-- First change at this level requiring 'target' to be copied.
						result = table.clone(target :: any) :: any
						hasBeenCopied = true
					end
					(result :: any)[key] = reconciledSubTable
				end
			else
				-- 'targetValue' is not a table (or is nil), but 'sourceValue' is a table.
				-- This is an overwrite or an addition of a new table.
				-- Use 'sourceTableValue's reference directly.
				-- This always constitutes a change unless targetValue was already identically sourceTableValue (rare).
				if not hasBeenCopied then
					result = table.clone(target :: any) :: any
					hasBeenCopied = true
				end
				(result :: any)[key] = sourceTableValue
			end
		else
			-- 'sourceValue' is a primitive (number, string, boolean).
			-- (Note: nil sourceValue means key is absent from source, handled by Pass 2 for deletions)
			-- A change is needed if 'targetValue' is different from 'sourceValue'.
			if targetValue ~= sourceValue then
				if not hasBeenCopied then
					result = table.clone(target :: any) :: any
					hasBeenCopied = true
				end
				(result :: any)[key] = sourceValue
			end
		end
	end

	-- Pass 2: Iterate over original 'target's keys to handle deletions.
	-- If a key was in 'target' but is not in 'source', it should be removed from 'result'.
	-- ('source' is non-empty here).
	for keyInTarget in target :: any do
		if (source :: any)[keyInTarget] == nil then -- Key is in 'target' but absent in 'source'.
			if not hasBeenCopied then
				-- This deletion is the first change requiring 'target' to be copied.
				result = table.clone(target :: any) :: any
				hasBeenCopied = true
			end
			-- Remove the key from 'result' by setting its value to nil.
			(result :: any)[keyInTarget] = nil
		end
	end

	-- If 'hasBeenCopied' is false, no merging operations (updates, additions, or deletions)
	-- resulted in any change to 'target' at this level. The original 'target' is returned.
	-- Otherwise, 'result' (the shallow copy with reconciled changes) is returned.
	return result
end

return {
	copyDeep = copyDeep,
	mergeDeep = mergeDeep,
	mergeShallow = mergeShallow,
	equalsDeep = equalsDeep,
	freezeDeep = freezeDeep,
	map = map,
	reconcileDeep = reconcileDeep,
}
