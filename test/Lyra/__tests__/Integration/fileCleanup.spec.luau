--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Tables = require(ReplicatedStorage.Packages.Lyra.Tables)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("File Cleanup", function()
	local Store

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

	beforeEach(function()
		jest.useFakeTimers()
		local realConstants = jest.requireActual(ReplicatedStorage.Packages.Lyra.Constants)
		jest.mock(ReplicatedStorage.Packages.Lyra.Constants, function()
			return Tables.mergeShallow(realConstants, {
				MAX_CHUNK_SIZE = 15,
			})
		end)

		Store = require(ReplicatedStorage.Packages.Lyra.Store)

		mockData = MockDataStoreService.new()
		mockMemory = MockMemoryStoreService.new()

		store = makeStore()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	it("clean up file partial write failure", function()
		store:load("player1")
		jest.advanceTimersByTime(1000)

		store:update("player1", function(data)
			data.coins = 100
			return true
		end)

		MockDataStoreService.queueError(mockData, "SetAsync", "fake error")
		local removeMock = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)

		local saveRejected = false
		store:unload("player1"):catch(function()
			saveRejected = true
		end)

		jest.advanceTimersByTime(1000)

		expect(saveRejected).toBe(true)
		expect(removeMock).toBeCalled()

		store:load("player1")
		jest.advanceTimersByTime(1000)

		local getP = store:get("player1")
		jest.advanceTimersByTime(1000)

		return expect(getP).resolves.toEqual({ coins = 0, inventory = {} })
	end)

	it("clean up file multiple partial write failures", function()
		store:load("player1")
		store:load("player2")
		store:load("player3")
		jest.advanceTimersByTime(1000)

		store:update("player1", function(data)
			data.coins = 100
			return true
		end)
		store:update("player2", function(data)
			data.coins = 100
			return true
		end)
		store:update("player3", function(data)
			data.coins = 100
			return true
		end)

		local setMock, realSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
		setMock.mockImplementation(function(self, key, ...)
			if key:match("%-%d+$") then
				MockDataStoreService.queueError(mockData, "SetAsync", "fake error")
			end
			return realSet(self, key, ...)
		end)
		local removeMock = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)

		local savesRejected = 0
		store:unload("player1"):catch(function()
			savesRejected += 1
		end)
		store:unload("player2"):catch(function()
			savesRejected += 1
		end)
		store:unload("player3"):catch(function()
			savesRejected += 1
		end)

		jest.advanceTimersByTime(1000)

		expect(savesRejected).toBe(3)
		expect(removeMock).toBeCalled()
	end)

	it("should retry orphan file cleanup if the request budget is insufficient at first", function()
		store:load("player1")
		jest.advanceTimersByTime(1000)

		store:update("player1", function(data)
			data.coins = 100
			return true
		end)

		MockDataStoreService.setRequestBudget(mockData, "SetAsync", 1)
		MockDataStoreService.queueError(mockData, "SetAsync", "fake error")
		local removeMock = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)

		store:unload("player1"):catch(function() end)
		jest.advanceTimersByTime(1000)

		expect(removeMock).toBeCalledTimes(0)

		MockDataStoreService.setRequestBudget(mockData, "SetAsync", 100)
		jest.advanceTimersByTime(1000)

		expect(removeMock).toBeCalled()
	end)

	it("should clean up old file after successful write of new file", function()
		store:load("player1")
		jest.advanceTimersByTime(1000)

		store:update("player1", function(data)
			data.coins = 100
			return true
		end)
		store:save("player1")
		jest.advanceTimersByTime(1000)

		local removeMock = MockDataStoreService.mockStoreMethod(mockData, "RemoveAsync", jest)

		store:update("player1", function(data)
			data.coins = 200
			return true
		end)
		store:save("player1")
		jest.advanceTimersByTime(1000)

		expect(removeMock).toBeCalled()
		expect(store:get("player1")).resolves.toEqual({ coins = 200, inventory = {} })
	end)
end)
