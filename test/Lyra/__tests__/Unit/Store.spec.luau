local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Promise = require(ReplicatedStorage.Packages.Lyra.Promise)
local Store = require(ReplicatedStorage.Packages.Lyra.Store)
local Tables = require(ReplicatedStorage.Packages.Lyra.Tables)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("Store", function()
	local mockData
	local mockMemory
	local store

	local function makeStore(config)
		config = Tables.mergeShallow({
			name = "session test",
			template = { coins = 0, inventory = {} },
			schema = function(data)
				return typeof(data) == "table" and typeof(data.coins) == "number" and typeof(data.inventory) == "table",
					"schema validation failed"
			end,

			migrationSteps = {},

			dataStoreService = mockData,
			memoryStoreService = mockMemory,
		}, config)

		return Store.createStore(config)
	end

	local function crash()
		local snap = MockDataStoreService.snapshot(mockData)
		for _ = 1, 5 do
			jest.advanceTimersByTime(1000)
		end
		mockData = MockDataStoreService.new()
		mockMemory = MockMemoryStoreService.new()
		store = makeStore()
		MockDataStoreService.restore(mockData, snap)
	end

	beforeEach(function()
		mockData = MockDataStoreService.new()
		mockMemory = MockMemoryStoreService.new()

		store = makeStore()

		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	describe("createStore", function()
		it("creates a store with a valid configuration", function()
			local ctx = store._ctx
			expect(ctx).toBeDefined()

			expect(ctx.name).toBe("session test")
			expect(ctx.template).toEqual({ coins = 0, inventory = {} })
			expect(ctx.migrationSteps).toEqual({})
			expect(ctx.dataStoreService).toBe(mockData)
			expect(ctx.memoryStoreService).toBe(mockMemory)
		end)

		it("throws an error if the template fails schema validation", function()
			local err = "schema validation failed"
			local fn = function()
				makeStore({
					template = { coins = "not a number", inventory = {} },
				})
			end

			expect(fn).toThrow(err)
		end)

		it("mutating a leaked table reference errors", function()
			local leakedData
			store:load("player1")
			store:update("player1", function(data)
				leakedData = data
				data.coins = 999
				return true
			end)
			jest.advanceTimersByTime(1000)

			expect(function()
				leakedData.coins = 123
			end).toThrow("attempt to modify a readonly table")
		end)

		it.todo("creates a store with useMock enabled in Studio")
		it.todo("fails if useMock is enabled outside of Studio")
		it.todo("handles store creation with no migration steps")
		it.todo("handles store creation with defined migration steps")
		it.todo("handles store creation with an importLegacyData function")
	end)

	describe("load(key)", function()
		it("loads a key successfully when not already loaded", function()
			store:load("player1")
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			expect(data).resolves.toEqual({ coins = 0, inventory = {} })
		end)

		it("resolves immediately if the key is already loaded", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			local p = store:load("player1")
			expect(p).resolves.toBeNil()
		end)

		it("properly re-loads after unloading in-progress load", function()
			local p1 = store:load("player1")
			local p2 = store:unload("player1")
			local p3 = store:load("player1")
			jest.advanceTimersByTime(10000)

			return expect(p1).rejects
				.toMatch("Load was cancelled")
				:andThen(function()
					return expect(p2).resolves.toBeNil()
				end)
				:andThen(function()
					return expect(p3).resolves.toBeNil()
				end)
		end)

		it("rejects if the store is closed", function()
			store:close()

			local p = store:load("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("Store is closed")
		end)

		it("rejects if load is already in progress for the same key", function()
			local p1 = store:load("player1")
			local p2 = store:load("player1")
			jest.advanceTimersByTime(1000)

			return expect(p1).resolves.toBeNil():andThen(function()
				return expect(p2).rejects.toMatch("Load already in progress")
			end)
		end)

		it("calls importLegacyData if no existing data", function()
			local importLegacyMock, importLegacyFn = jest.fn(function()
				return Promise.resolve({ coins = 999, inventory = {} })
			end)
			local myStore = makeStore({
				importLegacyData = importLegacyFn,
			})

			local p = myStore:load("player1")
			local data = myStore:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).resolves.toBeNil():andThen(function()
				expect(importLegacyMock).toBeCalledTimes(1)
				expect(importLegacyMock).toBeCalledWith("player1")
				return expect(data).resolves.toEqual({ coins = 999, inventory = {} })
			end)
		end)

		it("rejects if importLegacyData errors", function()
			local importLegacyMock, importLegacyFn = jest.fn(function()
				error("test error", 0)
			end)
			local myStore = makeStore({
				importLegacyData = importLegacyFn,
			})

			local p = myStore:load("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("test error"):andThen(function()
				expect(importLegacyMock).toBeCalledTimes(1)
				expect(importLegacyMock).toBeCalledWith("player1")
			end)
		end)

		it("uses template if importLegacyData returns nil", function()
			local importLegacyMock, importLegacyFn = jest.fn(function()
				return Promise.resolve(nil)
			end)
			local myStore = makeStore({
				template = { coins = 1234, inventory = { "anItem" } },
				importLegacyData = importLegacyFn,
			})

			local p = myStore:load("player1")
			local data = myStore:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).resolves.toBeNil():andThen(function()
				expect(importLegacyMock).toBeCalledTimes(1)
				expect(importLegacyMock).toBeCalledWith("player1")
				return expect(data).resolves.toEqual({ coins = 1234, inventory = { "anItem" } })
			end)
		end)

		it.todo("applies migrations after loading")

		it("retains lock until unload is called", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			local isActive = store:probeLockActive("player1")
			jest.advanceTimersByTime(1000)
			expect(isActive:expect()).toBe(true)

			for _ = 1, 240 do
				jest.advanceTimersByTime(1000)
			end

			isActive = store:probeLockActive("player1")
			jest.advanceTimersByTime(1000)
			expect(isActive:expect()).toBe(true)

			local p = store:unload("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).resolves.toBeNil():andThen(function()
				isActive = store:probeLockActive("player1")
				jest.advanceTimersByTime(1000)
				expect(isActive:expect()).toBe(false)
			end)
		end)

		it.todo("supports specifying userIds during load and stores them")

		it("handles dataStoreRetry errors gracefully and eventually fails after retries", function()
			MockDataStoreService.queueError(mockData, "GetAsync", "DataStoreRetry", 6)

			local p = store:load("player1")
			jest.advanceTimersByTime(50000)

			return expect(p).rejects.toMatch("DataStoreRetry")
		end)

		it.todo("rejects if the lock is lost mid-load")

		it("works with concurrent loads of different keys", function()
			local promises = {}
			for i = 1, 10 do
				promises[2 * i - 1] = store:load(`player{i}`)
				promises[2 * i] = store:get(`player{i}`)
			end

			jest.advanceTimersByTime(20000)

			return expect(Promise.all(promises)).resolves.never.toBeNil()
		end)
	end)

	describe("unload(key)", function()
		it("unloads a loaded key and saves changes", function()
			store:load("player1")
			store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			store:save("player1")
			jest.advanceTimersByTime(1000)

			store:unload("player1")
			jest.advanceTimersByTime(1000)

			store:load("player1")
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).resolves.toEqual({ coins = 999, inventory = {} })
		end)

		it("does nothing if the key was never loaded", function()
			return expect(store:unload("player1")).resolves.toBeNil()
		end)

		it("cancels an ongoing load when unload is called", function()
			local p1 = store:load("player1")
			local p2 = store:unload("player1")
			jest.advanceTimersByTime(10000)

			return expect(p1).rejects.toMatch("Load was cancelled"):andThen(function()
				return expect(p2).resolves.toBeNil()
			end)
		end)

		it("rejects if the store is closed", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			store:close()

			local p = store:unload("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("Store is closed")
		end)

		it("properly releases locks", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			store:unload("player1")
			jest.advanceTimersByTime(1000)

			local isActive = store:probeLockActive("player1")
			jest.advanceTimersByTime(1000)
			expect(isActive:expect()).toBe(false)
		end)

		it.todo("finalizes orphaned files handling before completion")
	end)

	describe("get(key)", function()
		it("returns the current data for a loaded key", function()
			store:load("player1")
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).resolves.toEqual({ coins = 0, inventory = {} })
		end)

		it("rejects if the key is not loaded", function()
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).rejects.toMatch("Key not loaded")
		end)

		it("rejects if the store is closed", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			store:close()

			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).rejects.toMatch("Store is closed")
		end)

		it("returns frozen data that cannot be mutated directly", function()
			store:load("player1")
			local p = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).resolves.toEqual({ coins = 0, inventory = {} }):andThen(function()
				local data = p:expect()
				expect(function()
					data.coins = 100
				end).toThrow("attempt to modify a readonly table")
			end)
		end)
	end)

	describe("update(key, transformFunction)", function()
		it("applies a valid transform function and commits changes", function()
			store:load("player1")
			store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).resolves.toEqual({ coins = 999, inventory = {} })
		end)

		it("skips commit if transform returns false", function()
			store:load("player1")
			store:update("player1", function(data)
				data.coins = 999
				return false
			end)
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).resolves.toEqual({ coins = 0, inventory = {} })
		end)

		it("resolves with true if commit is successful", function()
			store:load("player1")
			local p = store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			jest.advanceTimersByTime(1000)

			return expect(p).resolves.toBe(true)
		end)

		it("resolves with false if commit is skipped", function()
			store:load("player1")
			local p = store:update("player1", function(data)
				data.coins = 999
				return false
			end)
			jest.advanceTimersByTime(1000)

			return expect(p).resolves.toBe(false)
		end)

		it("rejects if transform throws an error", function()
			store:load("player1")
			local p = store:update("player1", function()
				error("test error", 0)
			end)
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("test error")
		end)

		it("rejects if transform returns a non-boolean value", function()
			store:load("player1")
			local p = store:update("player1", function()
				return 42 :: any
			end)
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("transformFunction must return a boolean")
		end)

		it("rejects if schema validation fails after transform", function()
			store:load("player1")
			local p = store:update("player1", function(data)
				data.coins = "not a number"
				return true
			end)
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("schema validation failed")
		end)

		it("rejects if the store is closed", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			store:close()

			local p = store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("Store is closed")
		end)

		it("rejects if the key is not loaded", function()
			local p = store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("Key not loaded")
		end)

		it("prevents concurrent updates from interfering", function()
			store:load("player1")
			store:load("player2")
			jest.advanceTimersByTime(1000)

			local p1 = store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			local p2 = store:update("player2", function(data)
				data.coins = 123
				return true
			end)
			jest.advanceTimersByTime(1000)

			return expect(p1).resolves.toBe(true):andThen(function()
				return expect(p2).resolves.toBe(true)
			end)
		end)

		it("should apply updates in call order", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			local expectedOrder = {}
			local order = {}
			local promises = {}
			for i = 1, 100 do
				expectedOrder[i] = i

				promises[i] = store
					:update("player1", function(data)
						data.coins = i
						return true
					end)
					:andThenCall(table.insert, order, i)
			end
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(Promise.all(promises)).resolves.never.toBeNil():andThen(function()
				expect(order).toEqual(expectedOrder)
				return expect(data).resolves.toEqual({ coins = 100, inventory = {} })
			end)
		end)

		it("ensures transformFunction cannot yield", function()
			store:load("player1")
			local p = store:update("player1", function()
				wait(1)
				return true
			end)
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("attempt to yield")
		end)

		it.todo("creates a changeSet entry that persists until saved")
	end)

	describe("tx(keys, transformFunction)", function()
		it.todo("commits changes to multiple loaded keys atomically")
		it.todo("handles single key transactions as a normal update")
		it.todo("rejects if any key in the transaction is not loaded")
		it.todo("rejects if the store is closed")
		it.todo("rejects if transform returns false (no commit)")
		it.todo("rejects if transform throws an error")
		it.todo("rejects if transform modifies the set of keys")
		it.todo("rejects if schema validation fails for any updated key")
		it.todo("ensures atomicity: if a crash occurs before commit, revert changes")
		it.todo("ensures atomicity: if a crash occurs after commit, changes persist")
		it.todo("handles no-op transactions gracefully (no changes)")
		it.todo("prevents concurrent updates or tx calls on the same keys while active")
		it.todo("properly cleans up tx entries (SetAsync/RemoveAsync on txStore)")
	end)

	describe("save(key)", function()
		it("saves changes for a loaded key", function()
			store:load("player1")
			store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			store:save("player1")
			jest.advanceTimersByTime(1000)

			crash()

			store:load("player1")
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).resolves.toEqual({ coins = 999, inventory = {} })
		end)

		it("no-ops if there are no changes to save", function()
			store:load("player1")
			store:save("player1")
			jest.advanceTimersByTime(1000)

			local setMock = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)

			store:save("player1")
			jest.advanceTimersByTime(1000)

			expect(setMock).toBeCalledTimes(0)
		end)

		it("rejects if the store is closed", function()
			store:load("player1")
			store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			jest.advanceTimersByTime(1000)

			store:close()

			local p = store:save("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("Store is closed")
		end)

		it("rejects if the key is not loaded", function()
			local p = store:save("player1")
			jest.advanceTimersByTime(1000)

			return expect(p).rejects.toMatch("Key not loaded")
		end)
	end)

	describe("close()", function()
		it("unloads loaded sessions", function()
			store:load("player1")
			store:load("player2")
			jest.advanceTimersByTime(1000)

			store:close()
			jest.advanceTimersByTime(1000)

			local isActive1 = store:probeLockActive("player1")
			local isActive2 = store:probeLockActive("player2")
			jest.advanceTimersByTime(1000)

			expect(isActive1:expect()).toBe(false)
			expect(isActive2:expect()).toBe(false)
		end)

		it("cancels ongoing loads before closing", function()
			local p1 = store:load("player1")
			local p2 = store:load("player2")
			store:close()
			jest.advanceTimersByTime(1000)

			return expect(p1).rejects.toMatch("Load was cancelled"):andThen(function()
				return expect(p2).rejects.toMatch("Load was cancelled")
			end)
		end)

		it("ensures all data is saved before fully closing", function()
			store:load("player1")
			store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			store:save("player1")
			jest.advanceTimersByTime(1000)

			store:close()
			jest.advanceTimersByTime(1000)

			crash()

			store:load("player1")
			local data = store:get("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).resolves.toEqual({ coins = 999, inventory = {} })
		end)

		it("rejects any further operations after close", function()
			local p1 = store:load("player1")
			jest.advanceTimersByTime(1000)

			store:close()

			local p2 = store:update("player1", function(data)
				data.coins = 999
				return true
			end)
			local p3 = store:save("player1")
			local p4 = store:tx({ "player1" }, function(state)
				state.player1.coins = 999
				return true
			end)
			local p5 = store:unload("player1")
			jest.advanceTimersByTime(1000)

			return expect(p1).resolves
				.toBeNil()
				:andThen(function()
					return expect(p2).rejects.toMatch("Store is closed")
				end)
				:andThen(function()
					return expect(p3).rejects.toMatch("Store is closed")
				end)
				:andThen(function()
					return expect(p4).rejects.toMatch("Store is closed")
				end)
				:andThen(function()
					return expect(p5).rejects.toMatch("Store is closed")
				end)
		end)
	end)

	describe("probeLockActive(key)", function()
		it("returns true if the key is currently locked due to a loaded session", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			local isActive = store:probeLockActive("player1")
			jest.advanceTimersByTime(1000)

			expect(isActive:expect()).toBe(true)
		end)

		it("returns false if the key is not loaded or lock not acquired", function()
			local isActive = store:probeLockActive("player1")
			jest.advanceTimersByTime(1000)

			expect(isActive:expect()).toBe(false)
		end)

		it("works after store is closed, returns false for previously loaded key", function()
			store:load("player1")
			jest.advanceTimersByTime(1000)

			store:close()
			jest.advanceTimersByTime(1000)

			local isActive = store:probeLockActive("player1")
			jest.advanceTimersByTime(1000)

			expect(isActive:expect()).toBe(false)
		end)
	end)

	describe("peek(key)", function()
		it("returns data for a key", function()
			store:load("player1")
			store:update("player1", function(data)
				data.coins = 123
				return true
			end)
			jest.advanceTimersByTime(1000)

			store:unload("player1")
			jest.advanceTimersByTime(1000)

			local data = store:peek("player1")
			jest.advanceTimersByTime(1000)

			return expect(data).resolves.toEqual({ coins = 123, inventory = {} })
		end)
	end)

	describe("listVersions(params)", function()
		it.todo("lists versions of a key with default parameters")
		it.todo("lists versions of a key with specified sortDirection, minDate, maxDate, pageSize")
		it.todo("returns empty pages if no versions exist")
		it.todo("handles errors gracefully")
		it.todo("rejects if store is closed")
	end)

	describe("readVersion(key, version)", function()
		it.todo("reads a known version of a key successfully")
		it.todo("rejects if the version does not exist")
		it.todo("handles large files and retrieves the correct data")
		it.todo("rejects if store is closed")
	end)
end)
