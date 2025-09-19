local Tables = require(script.Parent.Tables)
local Types = require(script.Parent.Types)

--[[
  RFC 6902 implementation in Luau (Roblox) with two public functions:
    1) JSONPatch.applyPatch(doc, patch) -> applies the patch in-place (mutates & returns doc).
    2) JSONPatch.createPatch(original, modified) -> returns a minimal set of patch operations.
]]

--[[
	Based on https://github.com/Starcounter-Jack/JSON-Patch

	(The MIT License)

	Copyright (c) 2013, 2014, 2020 Joachim Wester

	Permission is hereby granted, free of charge, to any person obtaining
	a copy of this software and associated documentation files (the
	'Software'), to deal in the Software without restriction, including
	without limitation the rights to use, copy, modify, merge, publish,
	distribute, sublicense, and/or sell copies of the Software, and to
	permit persons to whom the Software is furnished to do so, subject to
	the following conditions:

	The above copyright notice and this permission notice shall be
	included in all copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
	EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
	MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
	IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
	CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
	TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
	SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

-- JSON Pointer Utilities

local function isArray(value: any): boolean
	if typeof(value) ~= "table" then
		return false
	end

	if next(value) == nil then
		return true
	end

	local length = #value

	if length == 0 then
		return false
	end

	local count = 0
	local sum = 0
	for key in value do
		if typeof(key) ~= "number" then
			return false
		end
		if key % 1 ~= 0 or key < 1 then
			return false
		end
		count += 1
		sum += key
	end

	return sum == (count * (count + 1) / 2)
end

local function unescapeSegment(segment: string): string
	-- ~1 -> '/'
	-- ~0 -> '~'
	local res = string.gsub(segment, "~1", "/")
	res = string.gsub(res, "~0", "~")
	return res
end

local function escapeSegment(segment: string): string
	-- / -> '~1'
	-- ~ -> '~0'
	local res = string.gsub(segment, "~", "~0")
	res = string.gsub(res, "/", "~1")
	return res
end

local function parsePointer(pointer: string): { string }
	-- An empty string "" means "root"
	if pointer == "" then
		return {}
	end
	if string.sub(pointer, 1, 1) ~= "/" then
		error("Invalid JSON pointer (must start with / or be empty)")
	end
	local raw = string.sub(pointer, 2) -- skip leading '/'
	local segments = string.split(raw, "/")
	for i, seg in segments do
		segments[i] = unescapeSegment(seg)
	end
	return segments
end

-- Patch Application

local function getArrayIndexOrError(key: string, length: number, op: string): number
	local idx = tonumber(key)
	if idx == nil then
		error(`'{op}' path must be a valid numeric index; got '{key}'`)
	end
	idx += 1 -- 0-based to 1-based
	if idx < 1 or idx > length then
		error(`Array {op} index {idx - 1} out of bounds for length {length}`)
	end
	return idx
end

local function isStringifiedNumberOk(key: string): boolean
	if key == "0" then
		return true
	end

	local num = tonumber(key)
	if num == nil then
		return false
	end

	local str = tostring(num)
	return str == key
end

local function applyOperation(doc: any, opObj: Types.PatchOperation): any
	local op = opObj.op
	if typeof(op) ~= "string" then
		error("'op' must be a string")
	end

	local path = opObj.path
	if typeof(path) ~= "string" then
		error("missing valid 'path' string")
	end
	local segments = parsePointer(path)

	local parent = doc
	for i = 1, (#segments - 1) do
		local seg = segments[i]

		if isArray(parent) then
			if not isStringifiedNumberOk(seg) then
				error(`Path segment '{seg}' is not a valid array index`)
			end
			seg = getArrayIndexOrError(seg, #parent, op) :: any
		end

		if parent[seg] == nil then
			error("add to a non-existent target")
		end

		if typeof(parent[seg]) ~= "table" then
			error("cannot 'add' into non-table parent")
		end

		parent = parent[seg]
	end

	if opObj.op == "add" then
		local value = opObj.value
		if value == nil then
			error("missing 'value' parameter")
		end

		-- If path is empty, replace entire doc
		if #segments == 0 then
			return Tables.copyDeep(value)
		end

		local key = segments[#segments]

		local parentIsArray = isArray(parent)

		-- There's complex behavior with adding to arrays/objects based on the
		-- key and what kind of table the parent is. We treat parent as an array
		-- IF:
		-- 1. It's an empty table AND the key is "-" (append is the only valid
		--      operation)
		-- 2. It's a non-empty array AND the key is a number or "-" (append or
		--    insert)
		--
		-- Otherwise, we treat it as an object.

		local isAddingIntoEmptyArray = parentIsArray and #parent == 0 and key == "-"
		local isAddingIntoPopulatedArray = parentIsArray and #parent > 0 and (tonumber(key) ~= nil or key == "-")

		if isAddingIntoEmptyArray or isAddingIntoPopulatedArray then
			if key == "-" then
				-- append
				table.insert(parent, Tables.copyDeep(value))
			else
				if not isStringifiedNumberOk(key) then
					error("add op shouldn't add to array with bad number")
				end

				local index = getArrayIndexOrError(key, #parent, op)
				table.insert(parent, index, Tables.copyDeep(value))
			end
		else
			if parentIsArray and #parent > 0 then
				error("Object operation on array target")
			end

			parent[key] = Tables.copyDeep(value)
		end

		return doc
	elseif opObj.op == "remove" then
		-- If path is empty, remove entire doc => doc becomes nil
		if #segments == 0 then
			return nil
		end

		local key = segments[#segments]
		if isArray(parent) and tonumber(key) ~= nil then
			if not isStringifiedNumberOk(key) then
				error("remove op shouldn't remove from array with bad number")
			end

			local index = getArrayIndexOrError(key, #parent, op)
			table.remove(parent, index)
		else
			if parent[key] == nil then
				error(`Cannot remove non-existent key '{key}'`)
			end

			parent[key] = nil
		end

		return doc
	elseif opObj.op == "replace" then
		local value = opObj.value
		if value == nil then
			error("missing 'value' parameter")
		end

		-- If path is empty, replace entire doc
		if #segments == 0 then
			return Tables.copyDeep(value)
		end

		local key = segments[#segments]
		if isArray(parent) and tonumber(key) ~= nil then
			if not isStringifiedNumberOk(key) then
				error("replace op shouldn't replace in array with bad number")
			end

			local index = getArrayIndexOrError(key, #parent, op)
			parent[index] = Tables.copyDeep(value)
		else
			if parent[key] == nil then
				error(("Cannot replace non-existent path '%s'"):format(key))
			end
			parent[key] = Tables.copyDeep(value)
		end

		return doc
	else
		error(`Unrecognized op '{op}'`)
	end
end

-- Patch Generation

local function keys(obj: { [any]: any }): { any }
	local result = {}
	for k in obj do
		table.insert(result, k)
	end
	return result
end

local function getZeroBasedKey(key: any, parentIsArray: boolean): string
	if not parentIsArray then
		return escapeSegment(key)
	end
	local numericKey = tonumber(key)
	if numericKey == nil then
		return escapeSegment(key)
	end
	return tostring(numericKey - 1)
end

local function generate(obj1: any, obj2: any, patches: { Types.PatchOperation }, path: string): ()
	if obj1 == obj2 then
		return
	end

	local newKeys = keys(obj2)
	local oldKeys = keys(obj1)
	local deleted = false

	local obj1IsArray = isArray(obj1)
	local obj2IsArray = isArray(obj2)

	local obj1VirtualLength = obj1IsArray and #obj1 or 0

	for i = #oldKeys, 1, -1 do
		local key = oldKeys[i]
		local oldVal = obj1[key]

		local isKeyInObj = obj2[key] ~= nil
		local isUndefinedInNonArray = obj2[key] == nil and oldVal ~= nil and not obj2IsArray

		if isKeyInObj and not isUndefinedInNonArray then
			local newVal = obj2[key]

			local bothAreTables = typeof(oldVal) == "table" and typeof(newVal) == "table"
			local sameArrayType = isArray(oldVal) == isArray(newVal)
			local bothAreSameKindOfTable = bothAreTables and sameArrayType

			if bothAreSameKindOfTable then
				generate(oldVal, newVal, patches, path .. "/" .. getZeroBasedKey(key, obj1IsArray))
			else
				if oldVal ~= newVal then
					table.insert(patches, {
						op = "replace",
						path = path .. "/" .. getZeroBasedKey(key, obj1IsArray),
						value = Tables.copyDeep(newVal),
					})
				end
			end
		elseif obj1IsArray == obj2IsArray then
			table.insert(patches, {
				op = "remove",
				path = path .. "/" .. getZeroBasedKey(key, obj1IsArray),
			})
			deleted = true
		else
			table.insert(patches, {
				op = "replace",
				path = path,
				value = obj2,
			})
		end
	end

	if not deleted and #newKeys == #oldKeys then
		return
	end

	for _, key in newKeys do
		if obj1[key] == nil and obj2[key] ~= nil then
			if obj1IsArray then
				obj1VirtualLength += 1

				local numericKey = tonumber(key)
				if numericKey ~= nil and numericKey == obj1VirtualLength then
					table.insert(patches, {
						op = "add",
						path = path .. "/-",
						value = Tables.copyDeep(obj2[key]),
					})

					continue
				end
			end

			table.insert(patches, {
				op = "add",
				path = path .. "/" .. getZeroBasedKey(key, obj2IsArray),
				value = Tables.copyDeep(obj2[key]),
			})
		end
	end
end

local JSONPatch = {}

function JSONPatch.applyPatch(doc: any, patch: { Types.PatchOperation }): any
	for _, operation in patch do
		doc = applyOperation(doc, operation)
	end
	return doc
end

function JSONPatch.createPatch(original: any, modified: any): { Types.PatchOperation }
	local patches = {}
	generate(original, modified, patches, "")
	return patches
end

return JSONPatch
