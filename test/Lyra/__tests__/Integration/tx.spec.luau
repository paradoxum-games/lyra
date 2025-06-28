local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Store = require(ReplicatedStorage.Packages.Lyra.Store)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("tx", function()
	local store
	local mockData
	local mockMemory

	local function resetStore(config: any?)
		local storeConfig = {
			name = "tx tests",
			template = { coins = 0 },
			dataStoreService = mockData,
			memoryStoreService = mockMemory,
			schema = function(data)
				return typeof(data.coins) == "number"
			end,
		}
		if config then
			for k, v in config do
				storeConfig[k] = v
			end
		end
		store = Store.createStore(storeConfig)
	end

	local function crash()
		local snap = MockDataStoreService.snapshot(mockData)
		store:close()
		for _ = 1, 5 do
			jest.advanceTimersByTime(1000)
		end
		MockDataStoreService.restore(mockData, snap)
	end

	beforeEach(function()
		jest.useFakeTimers()

		mockData = MockDataStoreService.new()
		mockMemory = MockMemoryStoreService.new()
		resetStore()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	it("crash before commit should result in abort", function()
		store:load("key1")
		store:load("key2")

		jest.advanceTimersByTime(1000)

		local key2Set = false
		local setMock, realSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
		setMock.mockImplementation(function(self, key, ...)
			if key == "key1" then
				local ret = table.pack(realSet(self, key, ...))
				key2Set = true
				return table.unpack(ret)
			end
			return realSet(self, key, ...)
		end)

		store:tx({ "key1", "key2" }, function(state)
			state.key1.coins += 10
			state.key2.coins += 10
			return true
		end)

		local i = 0
		while key2Set == false do
			i += 1
			if i > 1000 then
				break
			end
			jest.advanceTimersByTime(1)
		end

		crash()
		resetStore()

		store:load("key1")
		jest.advanceTimersByTime(1000)

		local key1Data = store:get("key1")
		jest.advanceTimersByTime(1000)

		expect(key2Set).toBe(true)
		return expect(key1Data).resolves.toEqual({ coins = 0 })
	end)

	it("crash after commit should save changed", function()
		store:load("key1")
		store:load("key2")

		jest.advanceTimersByTime(1000)

		local txCommitted = false
		local removeMock, realRemove = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)
		removeMock.mockImplementation(function(self, key, ...)
			local ret = table.pack(realRemove(self, key, ...))
			txCommitted = true
			return table.unpack(ret)
		end)

		store:tx({ "key1", "key2" }, function(state)
			state.key1.coins += 10
			state.key2.coins += 10
			return true
		end)

		local i = 0
		while txCommitted == false do
			i += 1
			if i > 1000 then
				break
			end
			jest.advanceTimersByTime(1)
		end

		crash()
		resetStore()

		local load1 = store:load("key1")
		local load2 = store:load("key2")
		jest.advanceTimersByTime(1000)

		load1:expect()
		load2:expect()

		local key1Data = store:get("key1")
		local key2Data = store:get("key2")
		jest.advanceTimersByTime(1000)

		return expect(key1Data).resolves.toEqual({ coins = 10 }):andThen(function()
			return expect(key2Data).resolves.toEqual({ coins = 10 })
		end)
	end)

	it("should reject if any key is not loaded", function()
		store:load("key1")
		jest.advanceTimersByTime(1000)

		local txPromise = store:tx({ "key1", "key2" }, function(state)
			state.key1.coins += 10
			state.key2.coins += 10
			return true
		end)

		return expect(txPromise).rejects.toEqual("Key not loaded: key2")
	end)

	it("should reject if store is closed", function()
		store:load("key1")
		store:load("key2")
		jest.advanceTimersByTime(1000)

		store:close()
		jest.advanceTimersByTime(1000)

		local txPromise = store:tx({ "key1", "key2" }, function(state)
			state.key1.coins += 10
			state.key2.coins += 10
			return true
		end)

		return expect(txPromise).rejects.toEqual("Store is closed")
	end)

	it("should reject if schema validation fails", function()
		store:load("key1")
		store:load("key2")
		jest.advanceTimersByTime(1000)

		local txPromise = store:tx({ "key1", "key2" }, function(state)
			state.key1.coins = "invalid"
			state.key2.coins += 10
			return true
		end)
		jest.advanceTimersByTime(1000)

		return expect(txPromise).rejects.toMatch("schema validation failed")
	end)

	it("should reject if keys are modified in transform", function()
		store:load("key1")
		store:load("key2")
		jest.advanceTimersByTime(1000)

		local txPromise = store:tx({ "key1", "key2" }, function(state)
			state.key3 = { coins = 10 }
			return true
		end)
		jest.advanceTimersByTime(1000)

		return expect(txPromise).rejects.toMatch("Keys changed in transaction")
	end)

	it("should handle single key changes as normal update", function()
		store:load("key1")
		store:load("key2")
		jest.advanceTimersByTime(1000)

		local keySet = false
		local setMock, realSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
		setMock.mockImplementation(function(self, key, ...)
			keySet = true
			return realSet(self, key, ...)
		end)

		local txPromise = store:tx({ "key1", "key2" }, function(state)
			state.key1.coins += 10
			return true
		end)

		jest.advanceTimersByTime(1000)

		return txPromise
			:andThen(function()
				expect(keySet).toBe(false)
				return store:get("key1")
			end)
			:andThen(function(key1Data)
				return expect(key1Data).toEqual({ coins = 10 })
			end)
	end)

	it("should early exit with no changes", function()
		store:load("key1")
		store:load("key2")
		jest.advanceTimersByTime(1000)

		local keySet = false
		local setMock, realSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
		setMock.mockImplementation(function(self, key, ...)
			keySet = true
			return realSet(self, key, ...)
		end)

		local txPromise = store:tx({ "key1", "key2" }, function()
			return true
		end)

		jest.advanceTimersByTime(1000)

		return expect(txPromise).resolves.toBe(true):andThen(function()
			expect(keySet).toBe(false)
		end)
	end)

	it("should prevent concurrent updates during transaction", function()
		store:load("key1")
		store:load("key2")
		jest.advanceTimersByTime(1000)

		local txPromise = store:tx({ "key1", "key2" }, function(state)
			state.key1.coins += 10
			state.key2.coins += 10
			return true
		end)

		local updateStarted = false

		local txCommitted = false
		local removeMock, realRemove = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)
		removeMock.mockImplementation(function(self, key, ...)
			local ret = table.pack(realRemove(self, key, ...))
			expect(updateStarted).toBe(false)
			txCommitted = true
			return table.unpack(ret)
		end)

		store:update("key1", function(data)
			updateStarted = true
			data.coins += 5
			return true
		end)

		jest.advanceTimersByTime(1000)

		return expect(txPromise).resolves
			.toBe(true)
			:andThen(function()
				expect(txCommitted).toBe(true)
				return store:get("key1")
			end)
			:andThen(function(key1Data)
				return expect(key1Data).toEqual({ coins = 15 })
			end)
	end)

	it("should abort when transformFunction returns false", function()
		store:load("key1")
		store:load("key2")
		jest.advanceTimersByTime(1000)

		local txPromise = store:tx({ "key1", "key2" }, function(state)
			state.key1.coins += 10
			state.key2.coins += 10
			return false
		end)

		jest.advanceTimersByTime(1000)

		return expect(txPromise).resolves.toBe(false):andThen(function()
			local key1Data = store:get("key1")
			local key2Data = store:get("key2")
			jest.advanceTimersByTime(1000)

			return expect(key1Data).resolves.toEqual({ coins = 0 }):andThen(function()
				return expect(key2Data).resolves.toEqual({ coins = 0 })
			end)
		end)
	end)

	describe("changedCallbacks", function()
		it("should call changed callbacks for keys modified in tx", function()
			local mock, mockFn = jest.fn()
			resetStore({
				changedCallbacks = { mockFn },
			})

			store:load("cbKey1")
			store:load("cbKey2")
			jest.advanceTimersByTime(1000)

			mock.mockClear() -- load calls changedCallbacks, clear before tx

			store:tx({ "cbKey1", "cbKey2" }, function(state)
				state.cbKey1.coins += 10
				state.cbKey2.coins += 20
				return true
			end)

			jest.advanceTimersByTime(1000)

			expect(mock).toHaveBeenCalledTimes(2)
			expect(mock).toHaveBeenCalledWith("cbKey1", { coins = 10 }, { coins = 0 })
			expect(mock).toHaveBeenCalledWith("cbKey2", { coins = 20 }, { coins = 0 })
		end)

		it("should not call changed callbacks if no keys changed", function()
			local mock, mockFn = jest.fn()
			resetStore({
				changedCallbacks = { mockFn },
			})

			store:load("noChangeKey")
			jest.advanceTimersByTime(1000)

			mock.mockClear() -- load calls changedCallbacks, clear before tx

			store:tx({ "noChangeKey" }, function(state)
				return true -- No changes
			end)

			jest.advanceTimersByTime(1000)

			expect(mock).never.toHaveBeenCalled()
		end)

		it("should reconcile mutable updates with copy-on-write semantics", function()
			local mock, mockFn = jest.fn()
			resetStore({
				changedCallbacks = { mockFn },
				template = { coins = 0, inventory = {} },
				schema = function(data)
					return typeof(data.inventory) == "table" and typeof(data.coins) == "number"
				end,
			})

			store:load("cbKeyTx1")
			store:load("cbKeyTx2")
			jest.advanceTimersByTime(1000)

			mock.mockClear() -- load calls changedCallbacks, clear before txImmutable

			store:tx({ "cbKeyTx1", "cbKeyTx2" }, function(state)
				state.cbKeyTx1.coins = 50
				state.cbKeyTx2.coins = 100
				return true
			end)
			jest.advanceTimersByTime(1000)

			expect(mock).toHaveBeenCalledTimes(2)

			local key1Args = mock.mock.calls[1]
			local key1NewData = key1Args[2]
			local key1OldData = key1Args[3]

			expect(key1NewData.inventory).toBe(key1OldData.inventory) -- Should be the same table
			expect(key1NewData.inventory).toEqual({})
			expect(key1OldData.inventory).toEqual({})

			local key2Args = mock.mock.calls[2]
			local key2NewData = key2Args[2]
			local key2OldData = key2Args[3]

			expect(key2NewData.inventory).toBe(key2OldData.inventory) -- Should be the same table
			expect(key2NewData.inventory).toEqual({})
			expect(key2OldData.inventory).toEqual({})

			mock.mockClear() -- load calls changedCallbacks, clear before txImmutable

			store:tx({ "cbKeyTx1", "cbKeyTx2" }, function(state)
				state.cbKeyTx1.inventory = { "item1", "item2" }
				state.cbKeyTx2.inventory = { "item3", "item4" }
				return true
			end)
			jest.advanceTimersByTime(1000)

			expect(mock).toHaveBeenCalledTimes(2)

			key1Args = mock.mock.calls[1]
			key1NewData = key1Args[2]
			key1OldData = key1Args[3]

			expect(key1NewData.inventory).never.toBe(key1OldData.inventory) -- Should be a new table
			expect(key1NewData.inventory).toEqual({ "item1", "item2" })
			expect(key1OldData.inventory).toEqual({})

			key2Args = mock.mock.calls[2]
			key2NewData = key2Args[2]
			key2OldData = key2Args[3]

			expect(key2NewData.inventory).never.toBe(key2OldData.inventory) -- Should be a new table
			expect(key2NewData.inventory).toEqual({ "item3", "item4" })
			expect(key2OldData.inventory).toEqual({})
		end)

		it("should reconcile mutable mutation in the single key changed case", function()
			local mock, mockFn = jest.fn()
			resetStore({
				changedCallbacks = { mockFn },
				template = { coins = 0, inventory = {} },
				schema = function(data)
					return typeof(data.inventory) == "table" and typeof(data.coins) == "number"
				end,
			})

			store:load("cbKeyTx1")
			jest.advanceTimersByTime(1000)

			mock.mockClear() -- load calls changedCallbacks, clear before txImmutable

			store:tx({ "cbKeyTx1" }, function(state)
				state.cbKeyTx1.coins = 50
				return true
			end)
			jest.advanceTimersByTime(1000)

			expect(mock).toHaveBeenCalledTimes(1)

			local key1Args = mock.mock.calls[1]
			local key1NewData = key1Args[2]
			local key1OldData = key1Args[3]

			expect(key1NewData.inventory).never.toBe(key1OldData.inventory) -- Should be a new table
			expect(key1NewData.inventory).toEqual({})
			expect(key1OldData.inventory).toEqual({})
		end)
	end)

	describe("txImmutable", function()
		it("should successfully commit changes when transform returns a new state", function()
			store:load("keyA")
			store:load("keyB")
			jest.advanceTimersByTime(1000)

			local originalA = store:get("keyA"):expect()
			local originalB = store:get("keyB"):expect()

			local txPromise = store:txImmutable({ "keyA", "keyB" }, function(state)
				local newState = {
					keyA = { coins = state.keyA.coins + 100 },
					keyB = { coins = state.keyB.coins + 50 },
				}
				return newState
			end)
			jest.advanceTimersByTime(2000) -- Allow time for tx processing and save

			expect(txPromise:expect()).toBe(true)

			local dataA = store:get("keyA"):expect()
			local dataB = store:get("keyB"):expect()
			jest.advanceTimersByTime(1000)

			expect(dataA.coins).toEqual(originalA.coins + 100)
			expect(dataB.coins).toEqual(originalB.coins + 50)

			-- Verify underlying data store reflects changes after a save cycle
			store:unload("keyA")
			store:unload("keyB")
			jest.advanceTimersByTime(1000)

			store:close()
			jest.advanceTimersByTime(5000)
			resetStore()

			local a = store:load("keyA")
			local b = store:load("keyB")
			jest.advanceTimersByTime(5000)
			print(a:expect(), b:expect())

			local finalDataA = store:get("keyA"):expect()
			local finalDataB = store:get("keyB"):expect()

			expect(finalDataA.coins).toEqual(originalA.coins + 100)
			expect(finalDataB.coins).toEqual(originalB.coins + 50)
		end)

		it("should abort transaction and not change data when transform returns false", function()
			store:load("key1")
			store:load("key2")
			jest.advanceTimersByTime(1000)

			local originalData1 = store:get("key1"):expect()
			local originalData2 = store:get("key2"):expect()
			jest.advanceTimersByTime(1000)

			local txPromise = store:txImmutable({ "key1", "key2" }, function(state)
				return false -- Abort
			end)
			jest.advanceTimersByTime(1000)

			expect(txPromise:expect()).toBe(false)

			local currentData1 = store:get("key1"):expect()
			local currentData2 = store:get("key2"):expect()
			jest.advanceTimersByTime(1000)

			expect(currentData1).toEqual(originalData1)
			expect(currentData2).toEqual(originalData2)
		end)

		it("should return true and not save if transform returns an identical new state", function()
			store:load("keyX")
			store:load("keyY")
			jest.advanceTimersByTime(1000)

			local initialX = store:get("keyX"):expect()
			local initialY = store:get("keyY"):expect()
			jest.advanceTimersByTime(1000)

			-- Ensure data is considered "saved" by performing an initial save
			store:save("keyX")
			store:save("keyY")
			jest.advanceTimersByTime(1000)
			expect(store._sessions.keyX:isSaved()).toBe(true)
			expect(store._sessions.keyY:isSaved()).toBe(true)

			local mockSetAsync = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)

			local txPromise = store:txImmutable({ "keyX", "keyY" }, function(state)
				return {
					keyX = { coins = state.keyX.coins }, -- Identical content
					keyY = { coins = state.keyY.coins }, -- Identical content
				}
			end)
			jest.advanceTimersByTime(1000)

			expect(txPromise:expect()).toBe(true)
			expect(mockSetAsync).toHaveBeenCalledTimes(0) -- No SetAsync should be called for tx marker or data if no change

			local currentX = store:get("keyX"):expect()
			local currentY = store:get("keyY"):expect()
			jest.advanceTimersByTime(1000)

			expect(currentX).toEqual(initialX)
			expect(currentY).toEqual(initialY)
			expect(store._sessions.keyX:isSaved()).toBe(true) -- Should remain saved
			expect(store._sessions.keyY:isSaved()).toBe(true) -- Should remain saved
		end)

		it("should reject if new state from transform fails schema validation", function()
			store:load("sKey1")
			store:load("sKey2")
			jest.advanceTimersByTime(1000)

			local txPromise = store:txImmutable({ "sKey1", "sKey2" }, function(state)
				return {
					sKey1 = { coins = "not-a-number" }, -- Invalid
					sKey2 = { coins = state.sKey2.coins + 5 },
				}
			end)
			jest.advanceTimersByTime(1000)

			return expect(txPromise).rejects.toMatch("schema validation failed for key 'sKey1'")
		end)

		it("should reject if transform function itself errors", function()
			store:load("errKey1")
			jest.advanceTimersByTime(1000)

			local txPromise = store:txImmutable({ "errKey1" }, function(state)
				error("Transform error in txImmutable!")
				return state -- Unreachable
			end)
			jest.advanceTimersByTime(1000)

			return expect(txPromise).rejects.toMatch("Transform error in txImmutable!")
		end)

		it("should reject if any key is not loaded", function()
			store:load("loadedKey")
			jest.advanceTimersByTime(1000)

			local txPromise = store:txImmutable({ "loadedKey", "unloadedKey" }, function(state)
				return state -- Should not reach here
			end)
			jest.advanceTimersByTime(1000)
			return expect(txPromise).rejects.toEqual("Key not loaded: unloadedKey")
		end)

		it("should reject if store is closed", function()
			store:load("cKey1")
			jest.advanceTimersByTime(1000)

			store:close()
			jest.advanceTimersByTime(1000)

			local txPromise = store:txImmutable({ "cKey1" }, function(state)
				return state
			end)
			return expect(txPromise).rejects.toEqual("Store is closed")
		end)

		it("should reject if keys are added in returned state", function()
			store:load("kAdd1")
			jest.advanceTimersByTime(1000)

			local txPromise = store:txImmutable({ "kAdd1" }, function(state)
				local newState = {
					kAdd1 = { coins = state.kAdd1.coins + 1 },
					kAdd2 = { coins = 100 }, -- Adding a key
				}
				return newState
			end)
			jest.advanceTimersByTime(1000)
			return expect(txPromise).rejects.toMatch("Keys changed in transaction")
		end)

		it("should reject if keys are removed in returned state", function()
			store:load("kRem1")
			store:load("kRem2")
			jest.advanceTimersByTime(1000)

			local txPromise = store:txImmutable({ "kRem1", "kRem2" }, function(state)
				local newState = {
					kRem1 = { coins = state.kRem1.coins + 1 },
					-- kRem2 is removed
				}
				return newState
			end)
			jest.advanceTimersByTime(1000)
			return expect(txPromise).rejects.toMatch("Keys changed in transaction")
		end)

		it("should handle single key change as normal update (no tx datastore ops)", function()
			store:load("singleKeyTxI")
			jest.advanceTimersByTime(1000)
			local originalData = store:get("singleKeyTxI"):expect()
			jest.advanceTimersByTime(1000)

			local mockSetAsync = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
			local mockRemoveAsync = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)

			local txPromise = store:txImmutable({ "singleKeyTxI" }, function(state)
				return {
					singleKeyTxI = { coins = state.singleKeyTxI.coins + 77 },
				}
			end)
			jest.advanceTimersByTime(1000)
			expect(txPromise:expect()).toBe(true)

			-- For single key update, txStore SetAsync/RemoveAsync should not be called
			expect(mockSetAsync).never.toHaveBeenCalledWith(
				expect.anything(),
				expect.stringMatching("%w+%-%w+%-%w+%-%w+%-%w+"),
				expect.anything()
			)
			expect(mockRemoveAsync).never.toHaveBeenCalledWith(
				expect.anything(),
				expect.stringMatching("%w+%-%w+%-%w+%-%w+%-%w+")
			)

			local newData = store:get("singleKeyTxI"):expect()
			jest.advanceTimersByTime(1000)
			expect(newData.coins).toEqual(originalData.coins + 77)
			expect(store._sessions.singleKeyTxI:isSaved()).toBe(false) -- Data changed, session unsaved

			-- Verify save works
			store:save("singleKeyTxI")
			jest.advanceTimersByTime(1000)
			expect(store._sessions.singleKeyTxI:isSaved()).toBe(true)
		end)

		it("crash after commit should save changed data (txImmutable)", function()
			store:load("crashKeyA")
			store:load("crashKeyB")
			jest.advanceTimersByTime(1000)

			local txCommitted = false
			local removeMock, realRemove = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)
			removeMock.mockImplementation(function(self, key, ...)
				local ret = table.pack(realRemove(self, key, ...))
				txCommitted = true
				return table.unpack(ret)
			end)

			store:txImmutable({ "crashKeyA", "crashKeyB" }, function(state)
				return {
					crashKeyA = { coins = state.crashKeyA.coins + 10 },
					crashKeyB = { coins = state.crashKeyB.coins + 20 },
				}
			end)

			local i = 0
			while txCommitted == false and i < 2000 do -- Increased timeout for safety
				i += 1
				jest.advanceTimersByTime(1)
			end
			expect(txCommitted).toBe(true) -- Ensure the commit phase was reached

			crash() -- Simulate crash
			resetStore() -- Reset store to load from "disk"

			store:load("crashKeyA")
			store:load("crashKeyB")
			jest.advanceTimersByTime(1000)

			local dataA = store:get("crashKeyA"):expect()
			local dataB = store:get("crashKeyB"):expect()
			jest.advanceTimersByTime(1000)

			expect(dataA.coins).toEqual(10)
			expect(dataB.coins).toEqual(20)
		end)

		describe("changedCallbacks", function()
			it("should call changed callbacks for keys modified in txImmutable", function()
				local mock, mockFn = jest.fn()
				resetStore({
					changedCallbacks = { mockFn },
				})

				store:load("cbKeyTxI1")
				store:load("cbKeyTxI2")
				jest.advanceTimersByTime(1000)

				mock.mockClear() -- load calls changedCallbacks, clear before txImmutable

				store:txImmutable({ "cbKeyTxI1", "cbKeyTxI2" }, function(state)
					return {
						cbKeyTxI1 = { coins = state.cbKeyTxI1.coins + 10 },
						cbKeyTxI2 = { coins = state.cbKeyTxI2.coins + 20 },
					}
				end)

				jest.advanceTimersByTime(1000)

				expect(mock).toHaveBeenCalledTimes(2)
				expect(mock).toHaveBeenCalledWith("cbKeyTxI1", { coins = 10 }, { coins = 0 })
				expect(mock).toHaveBeenCalledWith("cbKeyTxI2", { coins = 20 }, { coins = 0 })
			end)

			it("should not call changed callbacks if no keys changed in txImmutable", function()
				local mock, mockFn = jest.fn()
				resetStore({
					changedCallbacks = { mockFn },
				})

				store:load("noChangeKeyTxI")
				jest.advanceTimersByTime(1000)

				mock.mockClear() -- load calls changedCallbacks, clear before txImmutable

				store:txImmutable({ "noChangeKeyTxI" }, function(state)
					return state -- No changes
				end)

				jest.advanceTimersByTime(1000)

				expect(mock).never.toHaveBeenCalled()
			end)
		end)
	end)
end)
