local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Promise = require(ReplicatedStorage.Packages.Lyra.Promise)

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeAll = JestGlobals.beforeAll
local beforeEach = JestGlobals.beforeEach
local jest = JestGlobals.jest

local function call<T>(obj: any, method: string, ...: any): T
	local args = table.pack(...)
	local result = Promise.try(function()
		return obj[method](obj, table.unpack(args))
	end)
	jest.runAllTimers()
	return result:expect()
end

describe("MockMemoryStoreService", function()
	local mockService
	local hashMap

	beforeAll(function()
		jest.useFakeTimers()
	end)

	beforeEach(function()
		mockService = MockMemoryStoreService.new()
		hashMap = mockService:GetHashMap("TestMap")
	end)

	describe("SetAsync & GetAsync", function()
		it("should set and get a simple key-value pair", function()
			local res = call(hashMap, "SetAsync", "testKey", { foo = "bar" }, 10)
			expect(res).toBe(true)

			local val = call(hashMap, "GetAsync", "testKey")
			expect(val).toEqual({ foo = "bar" })
		end)

		it("should return nil for non-existent key", function()
			local val = call(hashMap, "GetAsync", "missingKey")
			expect(val).toBeNil()
		end)

		it("should overwrite existing key on SetAsync", function()
			local res1 = call(hashMap, "SetAsync", "overKey", "first", 10)
			expect(res1).toBe(true)

			local res2 = call(hashMap, "SetAsync", "overKey", "second", 10)
			expect(res2).toBe(true)

			local val = call(hashMap, "GetAsync", "overKey")
			expect(val).toBe("second")
		end)
	end)

	describe("Expiration", function()
		it("should error on invalid expiration", function()
			expect(function()
				call(hashMap, "SetAsync", "key", "value", -1)
			end).toThrow("InvalidRequest")
		end)

		it("should expire keys after given time", function()
			local res = call(hashMap, "SetAsync", "tempKey", "tempValue", 1)
			expect(res).toBe(true)

			jest.advanceTimersByTime(2000)

			local val = call(hashMap, "GetAsync", "tempKey")
			expect(val).toBeNil()
		end)
	end)

	describe("Value and Key Limits", function()
		it("should error on too long key", function()
			local longKey = string.rep("a", 129)
			expect(function()
				call(hashMap, "SetAsync", longKey, "value", 10)
			end).toThrow("InvalidRequest")
		end)

		it("should error on too large value", function()
			local largeValue = string.rep("a", 33 * 1024)
			expect(function()
				call(hashMap, "SetAsync", "largeValKey", largeValue, 10)
			end).toThrow("ItemValueSizeTooLarge")
		end)
	end)

	describe("UpdateAsync", function()
		it("should update existing key using transform function", function()
			local res = call(hashMap, "SetAsync", "updKey", { count = 10 }, 10)
			expect(res).toBe(true)

			local newVal = call(hashMap, "UpdateAsync", "updKey", function(oldVal)
				return { count = (oldVal.count or 0) + 5 }
			end, 10)
			expect(newVal).toEqual({ count = 15 })

			local finalVal = call(hashMap, "GetAsync", "updKey")
			expect(finalVal).toEqual({ count = 15 })
		end)

		it("should set value if key does not exist", function()
			local val = call(hashMap, "UpdateAsync", "newKey", function(oldVal)
				expect(oldVal).toBeNil()
				return { foo = "bar" }
			end, 10)
			expect(val).toEqual({ foo = "bar" })

			local getVal = call(hashMap, "GetAsync", "newKey")
			expect(getVal).toEqual({ foo = "bar" })
		end)

		it("should not remove key if transform returns nil", function()
			local value = { test = true }
			local res = call(hashMap, "SetAsync", "delKey", value, 10)
			expect(res).toBe(true)

			local val = call(hashMap, "UpdateAsync", "delKey", function(oldVal)
				expect(oldVal).toEqual(value)
				return nil
			end, 10)
			expect(val).toBeNil()

			local getVal = call(hashMap, "GetAsync", "delKey")
			expect(getVal).toEqual(value)
		end)
	end)

	describe("RemoveAsync", function()
		it("should remove an existing key", function()
			local res = call(hashMap, "SetAsync", "rmKey", "rmVal", 10)
			expect(res).toBe(true)

			call(hashMap, "RemoveAsync", "rmKey")

			local val = call(hashMap, "GetAsync", "rmKey")
			expect(val).toBeNil()
		end)

		it("should not error when removing a non-existent key", function()
			expect(function()
				call(hashMap, "RemoveAsync", "noKey")
			end).never.toThrow()
		end)
	end)

	describe("Rate Limits and Throttling", function()
		it("should eventually hit TotalRequestsOverLimit with many calls", function()
			local numRequests = 100
			local done = false
			local finishedCount = 0

			jest.useRealTimers()
			for _ = 1, numRequests do
				task.spawn(function()
					local success, err = pcall(function()
						hashMap:GetAsync("spamKey")
					end)

					finishedCount += 1

					if
						not success
						and (string.find(err, "TotalRequestsOverLimit") or string.find(err, "RequestThrottled"))
					then
						done = true
					end
				end)
			end

			while not done and finishedCount < numRequests do
				task.wait()
			end

			expect(done).toBe(true)
		end)
	end)
end)
