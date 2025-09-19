local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Tables = require(ReplicatedStorage.Packages.Lyra.Tables)
local reconcileDeep = Tables.reconcileDeep

local it = JestGlobals.it
local expect = JestGlobals.expect
local describe = JestGlobals.describe

describe("reconcileDeep", function()
	describe("Basic Reconciliation", function()
		it("should add new keys from source to an empty target", function()
			local target = {}
			local source = { a = 1, b = "hello" }
			local result = reconcileDeep(target, source)

			expect(result).toEqual(source)
			expect(result).never.toBe(target) -- A new table should be created.
		end)

		it("should add new keys from source to a non-empty target", function()
			local target = { x = 100 }
			local source = { a = 1, x = 100 }
			local result = reconcileDeep(target, source)

			expect(result).toEqual({ x = 100, a = 1 })
			expect(result).never.toBe(target)
		end)

		it("should update existing keys in target with primitive values from source", function()
			local target = { a = 1, b = 2 }
			local source = { a = 99, b = 2 }
			local result = reconcileDeep(target, source)

			expect(result).toEqual({ a = 99, b = 2 })
			expect(result).never.toBe(target)
		end)

		it("should remove keys from target that are absent in source", function()
			local target = { a = 1, b = 2, c = 3 }
			local source = { a = 1, c = 3 }
			local result = reconcileDeep(target, source)

			expect(result).toEqual({ a = 1, c = 3 })
			expect(result).never.toBe(target)
		end)

		it("should perform a combination of additions, updates, and deletions", function()
			local nestedUnchanged = { z = 100 }
			local target = { a = 1, b = 2, c = nestedUnchanged } -- b will be deleted
			local source = { a = 99, c = nestedUnchanged, d = 4 } -- a will be updated, d will be added

			local result = reconcileDeep(target, source)

			expect(result).toEqual({ a = 99, c = { z = 100 }, d = 4 })
			expect(result.c).toBe(nestedUnchanged) -- Important: unchanged nested table reference is preserved.
			expect(target).toEqual({ a = 1, b = 2, c = nestedUnchanged })
			expect(result).never.toBe(target)
		end)

		it("replaces a primitive with a table (primitive -> table)", function()
			local target = { a = 1 }
			local newTbl = { x = 5 }
			local source = { a = newTbl }

			local result = reconcileDeep(target, source)

			expect(result.a).toBe(newTbl)
			expect(result).never.toBe(target)
		end)

		it("adds a brand-new key whose value is a table", function()
			local target = {}
			local tbl = { foo = "bar" }
			local source = { k = tbl }

			local result = reconcileDeep(target, source)

			expect(result.k).toBe(tbl)
			expect(result).never.toBe(target)
		end)

		it("removes a key inside a nested table", function()
			local target = { outer = { keep = 1, drop = 2 } }
			local source = { outer = { keep = 1 } }

			local result = reconcileDeep(target, source)

			expect(result.outer.drop).toBeNil()
			expect(result.outer).never.toBe(target.outer)
		end)

		it("returns the source child reference when a nested table becomes empty", function()
			local target = { t = { a = 1 } }
			local source = { t = {} }

			local result = reconcileDeep(target, source)

			expect(result.t).toBe(source.t) -- child empty table comes from `source`
			expect(result).never.toBe(target)
		end)

		it("does not mutate either input table", function()
			local function deepCopy(tbl)
				local copy = {}
				for k, v in tbl do
					copy[k] = typeof(v) == "table" and deepCopy(v) or v
				end
				return copy
			end

			local target = { a = 1, b = { x = 2 } }
			local source = { a = 99, b = { x = 3 }, c = 4 }

			local originalTarget = deepCopy(target)
			local originalSource = deepCopy(source)

			-- Run reconciliation (result not needed for this assertion)
			reconcileDeep(target, source)

			expect(target).toEqual(originalTarget)
			expect(source).toEqual(originalSource)
		end)
	end)

	describe("Copy-On-Write Semantics", function()
		it("should return the original target table reference when reconciling a table with itself", function()
			local target = { a = 1, b = { x = 2 } }
			local result = reconcileDeep(target, target)

			expect(result).toBe(target)
		end)

		it(
			"should return the original target table reference if source and target are semantically identical",
			function()
				local target = { a = 1, b = { x = 2 } }
				local source = { a = 1, b = { x = 2 } }
				local result = reconcileDeep(target, source)

				expect(result).toBe(target)
			end
		)

		it("should return a new table reference if a key is added", function()
			local target = { a = 1 }
			local source = { a = 1, b = 2 }
			local result = reconcileDeep(target, source)

			expect(result).never.toBe(target)
		end)

		it("should return a new table reference if a table value is replaced with a primitive", function()
			local target = { a = { x = 1 } }
			local source = { a = 1 }
			local result = reconcileDeep(target, source)

			expect(result).never.toBe(target)
			expect(result.a).toBe(1)
		end)
	end)

	describe("Deep Reconciliation (Nested Tables)", function()
		it("should return a new top-level table if a change occurs only in a deeply nested table", function()
			local target = { level1 = { level2 = { value = 1 } } }
			local source = { level1 = { level2 = { value = 2 } } }
			local result = reconcileDeep(target, source)

			expect(result).never.toBe(target) -- Top level is new
			expect(result.level1).never.toBe(target.level1) -- Intermediate is new
			expect(result.level1.level2).never.toBe(target.level1.level2) -- Deepest is new
			expect(result.level1.level2.value).toBe(2)
		end)

		it("should preserve the reference of an unchanged nested table sibling when another is changed", function()
			local unchangedSibling = { isSame = true }
			local target = { a = unchangedSibling, b = { value = 1 } }
			local source = { a = { isSame = true }, b = { value = 2 } }
			local result = reconcileDeep(target, source)

			expect(result).never.toBe(target)
			expect(result.a).toBe(unchangedSibling) -- Critical check: this reference must be preserved.
			expect(result.b).never.toBe(target.b)
		end)

		it(
			"should preserve the target's nested table reference if it's semantically identical to the source's (but a different reference)",
			function()
				local target = { nested = { val = 10 } }
				local source = { nested = { val = 10 } }
				-- Ensure our test setup is correct: the nested tables are different references
				expect(target.nested).never.toBe(source.nested)

				local result = reconcileDeep(target, source)

				-- Since no semantic change occurred, the original target should be returned.
				expect(result).toBe(target)
				-- And its nested reference should be the original one.
				expect(result.nested).toBe(target.nested)
			end
		)
	end)

	describe("Edge Cases and Limitations", function()
		it("should return the original target reference when both target and source are empty tables", function()
			local target = {}
			local source = {}
			local result = reconcileDeep(target, source)
			expect(result).toBe(target)
		end)

		it("should return a new empty table when target has keys and source is empty", function()
			local target = { a = 1 }
			local source = {}
			local result = reconcileDeep(target, source)

			expect(result).toEqual({})
			expect(result).toBe(source)
			expect(result).never.toBe(target)
		end)

		it("should correctly handle tables with mixed string and number keys", function()
			local target = { [1] = "a", ["1"] = "b" }
			local source = { [1] = "c", ["1"] = "b" }
			local result = reconcileDeep(target, source)

			expect(result).toEqual({ [1] = "c", ["1"] = "b" })
			expect(result).never.toBe(target)
		end)
	end)
end)
