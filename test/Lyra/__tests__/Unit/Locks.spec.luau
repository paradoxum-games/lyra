local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Locks = require(ReplicatedStorage.Packages.Lyra.Locks)
local Promise = require(ReplicatedStorage.Packages.Lyra.Promise)
local Log = require(ReplicatedStorage.Packages.Lyra.Log)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Types = require(ReplicatedStorage.Packages.Lyra.Types)
local hashMapRetry = require(ReplicatedStorage.Packages.Lyra.hashMapRetry)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

describe("Locks", function()
	local mockMemory
	local storeContext: Types.StoreContext<any>
	local logger

	beforeEach(function()
		mockMemory = MockMemoryStoreService.new()

		logger = Log.createLogger(function() end)

		storeContext = {
			lockHashMap = mockMemory:GetHashMap("test-locks"),
			logger = logger,
		} :: Types.StoreContext<any>
		jest.useFakeTimers()
	end)

	afterEach(function()
		jest.clearAllTimers()
		jest.useRealTimers()
	end)

	local function acquireLock(key: string?, config: { [string]: any }?)
		local params = {
			storeContext = storeContext,
			key = key or "testKey",
			duration = 30,
			refreshInterval = 5,
		}
		if config then
			for k, v in config do
				params[k] = v
			end
		end
		return Locks.acquireLock(params)
	end

	local function getLock(key: string?, config: { [string]: any }?)
		local lockPromise = acquireLock(key, config)
		jest.advanceTimersByTime(1000)
		return lockPromise:expect()
	end

	describe("acquireLock", function()
		describe("basic locking behavior", function()
			it("should successfully acquire a lock when none exists", function()
				local lock = getLock()
				expect(lock.isLocked()).toBe(true)
			end)

			it("should prevent other processes from acquiring the same lock", function()
				getLock()
				local lock2Promise = acquireLock()

				for _ = 1, 35 do
					jest.advanceTimersByTime(1000)
				end
				return expect(lock2Promise).rejects.toMatch("Failed to acquire lock")
			end)

			it("should allow acquiring the lock after it expires", function()
				local lock1 = getLock("testKey", { duration = 2 })
				expect(lock1.isLocked()).toBe(true)

				for _ = 1, 2 do
					jest.advanceTimersByTime(1000)
				end
				expect(lock1.isLocked()).toBe(false)

				local lock2 = getLock("testKey")
				jest.advanceTimersByTime(1000)

				expect(lock2.isLocked()).toBe(true)
			end)

			it("should generate unique lock IDs for each acquisition", function()
				local lock1 = getLock()
				local id1Handle = hashMapRetry(function()
					return storeContext.lockHashMap:GetAsync("testKey")
				end)
				jest.advanceTimersByTime(500)
				local id1 = id1Handle.promise:expect()

				lock1.release()
				jest.advanceTimersByTime(1000)

				acquireLock()
				jest.advanceTimersByTime(1000)

				local id2Handle = hashMapRetry(function()
					return storeContext.lockHashMap:GetAsync("testKey")
				end)
				jest.advanceTimersByTime(500)
				local id2 = id2Handle.promise:expect()

				expect(id1).never.toBe(id2)
			end)
		end)

		describe("lock refresh behavior", function()
			it("should maintain lock", function()
				local lock = getLock("testKey", { duration = 10, refreshInterval = 2 })
				expect(lock.isLocked()).toBe(true)

				for _ = 1, 40 do
					jest.advanceTimersByTime(100)
					expect(lock.isLocked()).toBe(true)
				end
			end)

			it("should extend lock duration after successful refresh", function()
				local lock = getLock("testKey", { duration = 10, refreshInterval = 2 })
				for _ = 1, 4 do
					jest.advanceTimersByTime(1000)
					expect(lock.isLocked()).toBe(true)
				end

				for _ = 1, 20 do
					jest.advanceTimersByTime(100)
					expect(lock.isLocked()).toBe(true)
				end
			end)

			it("should stop refreshing after lock is released", function()
				local refreshCount = 0

				local updateMock, realUpdate = MockMemoryStoreService.mockHashMapMethod(mockMemory, "UpdateAsync", jest)
				updateMock.mockImplementation(function(...)
					refreshCount += 1
					return realUpdate(...)
				end)

				local lock = getLock("testKey", { duration = 10, refreshInterval = 2 })
				for _ = 1, 3 do
					jest.advanceTimersByTime(1000)
				end
				local initialCount = refreshCount
				lock.release()
				initialCount += 1 -- lock.release adds 1 update call
				jest.advanceTimersByTime(500)
				expect(refreshCount).toBe(initialCount)

				for _ = 1, 3 do
					jest.advanceTimersByTime(1000)
				end
				expect(refreshCount).toBe(initialCount)
			end)
		end)

		describe("lock release behavior", function()
			it("should successfully release an acquired lock", function()
				local lock = getLock()
				expect(lock.isLocked()).toBe(true)
				lock.release()
				jest.advanceTimersByTime(500)
				expect(lock.isLocked()).toBe(false)
			end)

			it("should allow immediate reacquisition after release", function()
				local lock1 = getLock()
				lock1.release()
				jest.advanceTimersByTime(500)

				expect(lock1.isLocked()).toBe(false)

				local p2 = acquireLock():andThen(function(lock2)
					expect(lock2.isLocked()).toBe(true)
				end)
				jest.advanceTimersByTime(5000)

				return p2
			end)

			it("should handle multiple release calls gracefully", function()
				local lock = getLock()
				lock.release()
				jest.advanceTimersByTime(500)

				expect(lock.isLocked()).toBe(false)

				lock.release()
				jest.advanceTimersByTime(500)

				expect(lock.isLocked()).toBe(false)
			end)

			it("should execute onLockLost callbacks when lock expires", function()
				local lock = getLock("testKey", { duration = 5 })
				local mock, fn = jest.fn()
				lock.onLockLost(fn)

				jest.advanceTimersByTime(6000)
				expect(mock).toBeCalledTimes(1)
			end)

			it("should transition status to released and call onLockLost when lock expires via timer", function()
				local lock = getLock("testKey", { duration = 5, refreshInterval = 20 }) -- Long refresh interval to ensure timer expiry happens first
				local mock, fn = jest.fn()
				lock.onLockLost(fn)

				-- Track UpdateAsync calls to ensure refresh stops
				local refreshCount = 0
				local updateMock, realUpdate = MockMemoryStoreService.mockHashMapMethod(mockMemory, "UpdateAsync", jest)
				updateMock.mockImplementation(function(...)
					refreshCount += 1
					return realUpdate(...)
				end)

				-- Advance time just past the duration
				jest.advanceTimersByTime(5000 + 100) -- 5s duration + small buffer

				-- Check callback and status
				expect(mock).toBeCalledTimes(1)
				expect(lock.isLocked()).toBe(false)

				-- Ensure no more refreshes happen after expiry
				local countAfterExpiry = refreshCount
				jest.advanceTimersByTime(30000) -- Advance well past potential refresh interval
				expect(refreshCount).toBe(countAfterExpiry)
			end)

			it("should transition status to released and call onLockLost when refresh fails", function()
				local lock = getLock("testKey", { duration = 10, refreshInterval = 2 })
				local mock, fn = jest.fn()
				lock.onLockLost(fn)

				-- Mock UpdateAsync to fail on the *first refresh attempt*
				local refreshAttempt = 0
				local updateMock = MockMemoryStoreService.mockHashMapMethod(mockMemory, "UpdateAsync", jest)
				updateMock.mockImplementation(function(...)
					refreshAttempt += 1
					return Promise.resolve(nil) -- Simulate lock taken by another
				end)

				-- Advance time to trigger the first refresh
				jest.advanceTimersByTime(2000 + 100) -- 2s refresh interval + small buffer

				-- Check callback and status due to refresh failure
				expect(mock).toBeCalledTimes(1)
				expect(lock.isLocked()).toBe(false)

				-- Ensure no more refreshes happen after failure
				local countAfterFailure = refreshAttempt
				jest.advanceTimersByTime(30000) -- Advance well past potential refresh interval
				expect(refreshAttempt).toBe(countAfterFailure)
			end)
		end)

		describe("error handling", function()
			it("should reject if lock cannot be acquired within duration", function()
				getLock()

				local promise = acquireLock("testKey", { duration = 2 })
				for _ = 1, 3 do
					jest.advanceTimersByTime(50000)
				end

				return expect(promise).rejects.toMatch("Failed to acquire lock")
			end)

			it("should clean up resources if cancelled during acquisition", function()
				local acquirePromise = acquireLock()
				acquirePromise:cancel()
				jest.advanceTimersByTime(1000)

				local promise = acquireLock():andThen(function(lock)
					expect(lock.isLocked()).toBe(true)
				end)
				jest.advanceTimersByTime(90000)
				return promise
			end)
		end)

		describe("callback management", function()
			it("should properly register and unregister onLockLost callbacks", function()
				local callback1, fn1 = jest.fn()
				local callback2, fn2 = jest.fn()

				local lock = getLock("testKey", { duration = 5 })
				local unregister1 = lock.onLockLost(fn1)
				lock.onLockLost(fn2)

				unregister1()

				for _ = 1, 6 do
					jest.advanceTimersByTime(1000)
				end
				expect(callback1).never.toBeCalled()
				expect(callback2).toBeCalledTimes(1)
			end)

			it("should execute all registered callbacks on expiry", function()
				local callback1, fn1 = jest.fn()
				local callback2, fn2 = jest.fn()
				local callback3, fn3 = jest.fn()

				local lock = getLock("testKey", { duration = 5 })
				lock.onLockLost(fn1)
				lock.onLockLost(fn2)
				lock.onLockLost(fn3)

				for _ = 1, 6 do
					jest.advanceTimersByTime(1000)
				end
				expect(callback1).toBeCalledTimes(1)
				expect(callback2).toBeCalledTimes(1)
				expect(callback3).toBeCalledTimes(1)
			end)
		end)
	end)

	describe("probeLockActive", function()
		describe("basic probing behavior", function()
			it("should return true for active locks", function()
				getLock()

				local p = Locks.probeLockActive({
					storeContext = storeContext,
					key = "testKey",
				})
				jest.advanceTimersByTime(500)

				return expect(p).resolves.toBe(true)
			end)

			it("should return false for expired locks", function()
				getLock("testKey", { duration = 2 })
				jest.advanceTimersByTime(3000)

				local p = Locks.probeLockActive({
					storeContext = storeContext,
					key = "testKey",
				})
				jest.advanceTimersByTime(500)

				return expect(p).resolves.toBe(false)
			end)

			it("should return false for non-existent locks", function()
				local promise = Locks.probeLockActive({
					storeContext = storeContext,
					key = "nonExistentKey",
				}):andThen(function(isActive)
					expect(isActive).toBe(false)
				end)
				jest.advanceTimersByTime(1000)

				return promise
			end)
		end)

		describe("error handling", function()
			it("should handle hashmap errors gracefully", function()
				MockMemoryStoreService.queueError(mockMemory, "GetAsync", "Simulated error")

				local promise = Locks.probeLockActive({
					storeContext = storeContext,
					key = "testKey",
				})
				jest.advanceTimersByTime(1000)

				return expect(promise).rejects.toBeDefined()
			end)
		end)
	end)

	describe("integration scenarios", function()
		it("should handle multiple concurrent lock attempts", function()
			local successfulLocks = 0
			local failedLocks = 0

			local promises = {}
			for _ = 1, 5 do
				table.insert(
					promises,
					acquireLock("sharedKey")
						:andThen(function()
							successfulLocks += 1
						end)
						:catch(function()
							failedLocks += 1
						end)
				)
				jest.advanceTimersByTime(100)
			end

			for _ = 1, 35 do
				jest.advanceTimersByTime(1000)
			end

			Promise.all(promises):expect()
			expect(successfulLocks).toBe(1)
			expect(failedLocks).toBe(4)
		end)
	end)
end)
