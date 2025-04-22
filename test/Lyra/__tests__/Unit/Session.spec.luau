local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Log = require(ReplicatedStorage.Packages.Lyra.Log)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Session = require(ReplicatedStorage.Packages.Lyra.Session)
local Types = require(ReplicatedStorage.Packages.Lyra.Types)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("Session", function()
	local mockData
	local mockMemory
	local ctx: Types.StoreContext<any>

	local function loadSession(key: string?, userIds: { number }?)
		local _key = key or "player1"
		return Session.load({
			key = _key,
			storeContext = ctx,
			userIds = userIds,
		})
	end

	local function getSession(...)
		local sessionPromise = loadSession(...)
		jest.advanceTimersByTime(1000)
		return sessionPromise:expect()
	end

	beforeEach(function()
		mockData = MockDataStoreService.new()
		mockMemory = MockMemoryStoreService.new()
		ctx = {
			name = "session test",
			template = { coins = 0, inventory = {} },
			schema = function(data)
				return typeof(data) == "table" and typeof(data.coins) == "number" and typeof(data.inventory) == "table"
			end,

			migrationSteps = {},

			dataStoreService = mockData,
			memoryStoreService = mockMemory,

			logger = Log.createLogger(function() end),
			changedCallbacks = {},

			recordStore = mockData:GetDataStore("session"),
			shardStore = mockData:GetDataStore("shards"),
			txStore = mockData:GetDataStore("tx"),
			lockHashMap = mockMemory:GetHashMap("locks"),

			disableReferenceProtection = false,
		}
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	describe("basic session behavior", function()
		it("should load a session with template data", function()
			local promise = getSession():get()
			jest.advanceTimersByTime(1000)
			return expect(promise).resolves.toEqual(ctx.template)
		end)

		it("should track changes correctly", function()
			local session = getSession()
			-- TODO: sessions are broadly considered unsaved on load
			expect(session:isSaved()).toBe(false)

			session:setData({ coins = 10, inventory = {} })
			expect(session:isSaved()).toBe(false)

			session:save()
			jest.advanceTimersByTime(1000)

			expect(session:isSaved()).toBe(true)
		end)

		it("should prevent modifications after session is closed", function()
			local session = getSession()
			session:unload()
			jest.advanceTimersByTime(1000)

			local p = session:update(function(data)
				data.coins += 10
				return true
			end)

			jest.advanceTimersByTime(1000)
			return expect(p).rejects.toEqual("Session is closed")
		end)
	end)

	describe("data validation", function()
		it("should reject invalid data in update", function()
			local promise = getSession():update(function(data: any)
				data.coins = "invalid"
				return true
			end)
			jest.advanceTimersByTime(1000)

			return expect(promise).rejects.toMatch("schema validation failed")
		end)

		it("should maintain data immutability", function()
			local session = getSession()
			local dataPromise = session:get()
			jest.advanceTimersByTime(1000)

			local data = dataPromise:expect()

			return expect(function()
				data.coins = 100
			end).toThrow()
		end)
	end)

	describe("autosave behavior", function()
		it("should automatically save changes", function()
			local session = getSession()
			session:startAutosaving()
			session:setData({ coins = 10, inventory = {} })

			jest.advanceTimersByTime(6 * 60 * 1000) -- Autosave interval + buffer

			expect(session:isSaved()).toBe(true)
		end)

		it("should stop autosaving when requested", function()
			local session = getSession()
			session:startAutosaving()
			session:setData({ coins = 10, inventory = {} })
			session:stopAutosaving()

			jest.advanceTimersByTime(6 * 60 * 1000)

			expect(session:isSaved()).toBe(false)
		end)
	end)

	describe("lock handling", function()
		it("should release lock on unload", function()
			local session = getSession()
			session:unload()
			jest.advanceTimersByTime(1000)

			expect(session.lockHandle.isLocked()).toBe(false)

			local p = loadSession()
			jest.advanceTimersByTime(2 * 60 * 1000)

			return expect(p).resolves.toBeDefined()
		end)

		it("should handle lock loss", function()
			local session = getSession()
			local updateMock = MockMemoryStoreService.mockHashMapMethod(mockMemory, "UpdateAsync", jest)
			updateMock.mockImplementation(function()
				task.wait(1000)
			end)

			-- Simulate lock loss
			jest.advanceTimersByTime(3 * 60 * 1000)
			expect(session.lockHandle.isLocked()).toBe(false)

			local p = session:update(function(data)
				data.coins += 10
				return true
			end)
			return expect(p).rejects.toEqual("Session is closed")
		end)
	end)

	describe("changedCallbacks", function()
		it("should call callbacks with nil oldData when data first loads", function()
			local callbackMock, callbackFn = jest.fn()
			ctx.changedCallbacks = { callbackFn }

			getSession()
			jest.advanceTimersByTime(1000)

			expect(callbackMock).toHaveBeenCalledTimes(1)
			expect(callbackMock).toHaveBeenCalledWith("player1", { coins = 0, inventory = {} }, nil)
		end)

		it("should call callbacks with previous data on subsequent updates", function()
			local callbackMock, callbackFn = jest.fn()
			ctx.changedCallbacks = { callbackFn }

			local session = getSession()
			jest.advanceTimersByTime(1000)
			callbackMock.mockClear()

			session:update(function(data)
				data.coins = 100
				return true
			end)
			jest.advanceTimersByTime(1000)

			expect(callbackMock).toHaveBeenCalledTimes(1)
			expect(callbackMock).toHaveBeenCalledWith(
				"player1",
				{ coins = 100, inventory = {} },
				{ coins = 0, inventory = {} }
			)
		end)

		it("should call multiple callbacks in order", function()
			local order = {}
			local callback1Mock, callback1Fn = jest.fn(function()
				table.insert(order, 1)
			end)
			local callback2Mock, callback2Fn = jest.fn(function()
				table.insert(order, 2)
			end)
			ctx.changedCallbacks = { callback1Fn, callback2Fn }

			getSession()
			jest.advanceTimersByTime(1000)

			expect(callback1Mock).toHaveBeenCalledTimes(1)
			expect(callback2Mock).toHaveBeenCalledTimes(1)
			expect(order).toEqual({ 1, 2 })
		end)
	end)

	describe("error handling", function()
		it("should handle DataStore errors during save", function()
			local session = getSession()

			MockDataStoreService.queueError(mockData, "SetAsync", "503: Service Unavailable", 5)

			session:setData({ coins = 10, inventory = {} })

			local p = session:save()
			jest.advanceTimersByTime(50000)

			return expect(p).rejects.toMatch("503: Service Unavailable")
		end)

		it("should retry on retryable errors", function()
			local session = getSession()

			MockDataStoreService.queueError(mockData, "SetAsync", "503: Service Unavailable", 2)
			local setSpy = jest.spyOn(mockData.mockStoreMeta, "SetAsync")

			session:setData({ coins = 100, inventory = {} })

			session:save()
			jest.advanceTimersByTime(30000)

			expect(setSpy).toHaveBeenCalledTimes(3)
			expect(session:isSaved()).toBe(true)
		end)
	end)
end)
