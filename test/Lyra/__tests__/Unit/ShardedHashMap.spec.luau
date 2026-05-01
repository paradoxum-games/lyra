local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Constants = require(ReplicatedStorage.Packages.Lyra.Constants)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local ShardedHashMap = require(ReplicatedStorage.Packages.Lyra.ShardedHashMap)
local Store = require(ReplicatedStorage.Packages.Lyra.Store)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach

-- Minimal recorder-stub for the MemoryStoreService interface. Avoids the
-- MockMemoryStoreService rate-limit/yield path so we can inspect routing
-- synchronously without pumping fake timers.
local function makeStubService()
	local service = {
		_hashMaps = {} :: { [string]: any },
		_calls = {} :: { { name: string, method: string, key: string } },
	}

	function service:GetHashMap(name: string)
		if self._hashMaps[name] then
			return self._hashMaps[name]
		end

		local calls = self._calls
		local shard = {
			_name = name,
			UpdateAsync = function(self, key: string)
				table.insert(calls, { name = self._name, method = "UpdateAsync", key = key })
				return key
			end,
			GetAsync = function(self, key: string)
				table.insert(calls, { name = self._name, method = "GetAsync", key = key })
				return nil
			end,
			RemoveAsync = function(self, key: string)
				table.insert(calls, { name = self._name, method = "RemoveAsync", key = key })
			end,
		}
		self._hashMaps[name] = shard
		return shard
	end

	return service
end

describe("ShardedHashMap", function()
	describe("hashKey", function()
		it("is deterministic for the same input", function()
			expect(ShardedHashMap.hashKey("player_42")).toBe(ShardedHashMap.hashKey("player_42"))
			expect(ShardedHashMap.hashKey("")).toBe(ShardedHashMap.hashKey(""))
		end)

		it("produces different hashes for different inputs", function()
			expect(ShardedHashMap.hashKey("player_1")).never.toBe(ShardedHashMap.hashKey("player_2"))
		end)

		it("tolerates empty, long, and non-ascii keys", function()
			local long = string.rep("x", 1024)
			expect(typeof(ShardedHashMap.hashKey(""))).toBe("number")
			expect(typeof(ShardedHashMap.hashKey(long))).toBe("number")
			expect(typeof(ShardedHashMap.hashKey("café"))).toBe("number")
		end)
	end)

	describe("pickShard", function()
		it("returns a 1-based index within [1, count]", function()
			for i = 1, 500 do
				local shard = ShardedHashMap.pickShard("key_" .. i, 4)
				expect(shard >= 1 and shard <= 4).toBe(true)
			end
		end)

		it("is deterministic across calls", function()
			expect(ShardedHashMap.pickShard("abc", 8)).toBe(ShardedHashMap.pickShard("abc", 8))
		end)

		it("distributes keys across shards (loose sanity check)", function()
			local counts = { 0, 0, 0, 0 }
			for i = 1, 1000 do
				local shard = ShardedHashMap.pickShard("player_" .. i, 4)
				counts[shard] += 1
			end
			-- Each shard should get >10% of a uniform 1000-key sample. This is a
			-- sanity bound, not a statistical guarantee.
			for i = 1, 4 do
				expect(counts[i] > 100).toBe(true)
			end
		end)
	end)

	describe("new", function()
		it("rejects shardCount < 2", function()
			local service = makeStubService()
			expect(function()
				ShardedHashMap.new(service :: any, "lyra/locks/foo", 1)
			end).toThrow()
			expect(function()
				ShardedHashMap.new(service :: any, "lyra/locks/foo", 0)
			end).toThrow()
		end)

		it("rejects non-integer shardCount", function()
			local service = makeStubService()
			expect(function()
				ShardedHashMap.new(service :: any, "lyra/locks/foo", 2.5)
			end).toThrow()
		end)

		it("eagerly creates shardCount HashMaps with /s{i}of{N} naming", function()
			local service = makeStubService()
			ShardedHashMap.new(service :: any, "lyra/locks/foo", 4)

			local names = {}
			for name in service._hashMaps do
				table.insert(names, name)
			end
			table.sort(names)

			expect(names).toEqual({
				"lyra/locks/foo/s1of4",
				"lyra/locks/foo/s2of4",
				"lyra/locks/foo/s3of4",
				"lyra/locks/foo/s4of4",
			})
		end)

		it("produces disjoint namespaces across different shardCounts (alias prevention)", function()
			local serviceA = makeStubService()
			local serviceB = makeStubService()
			ShardedHashMap.new(serviceA :: any, "lyra/locks/foo", 4)
			ShardedHashMap.new(serviceB :: any, "lyra/locks/foo", 8)

			for nameA in serviceA._hashMaps do
				expect(serviceB._hashMaps[nameA]).toBeNil()
			end
		end)
	end)

	describe("routing", function()
		it("routes UpdateAsync/GetAsync/RemoveAsync for a key to the same shard", function()
			local service = makeStubService()
			local shm = ShardedHashMap.new(service :: any, "base", 4)

			shm:UpdateAsync("player_1", function() end, 30)
			shm:GetAsync("player_1")
			shm:RemoveAsync("player_1")

			expect(#service._calls).toBe(3)
			local name = service._calls[1].name
			expect(service._calls[2].name).toBe(name)
			expect(service._calls[3].name).toBe(name)

			local expected = `base/s{ShardedHashMap.pickShard("player_1", 4)}of4`
			expect(name).toBe(expected)
		end)

		it("spreads traffic across shards for different keys", function()
			local service = makeStubService()
			local shm = ShardedHashMap.new(service :: any, "base", 4)

			for i = 1, 200 do
				shm:UpdateAsync("k_" .. i, function() end, 30)
			end

			local perShard: { [string]: number } = {}
			for _, c in service._calls do
				perShard[c.name] = (perShard[c.name] or 0) + 1
			end

			local hit = 0
			for _ in perShard do
				hit += 1
			end
			expect(hit).toBe(4)
		end)
	end)

	describe("Store.createStore integration", function()
		local mockData, mockMemory

		local function makeStore(name: string, lockShardCount: number?)
			Store.createStore({
				name = name,
				template = { coins = 0 },
				schema = function(data)
					return typeof(data) == "table" and typeof(data.coins) == "number", "bad"
				end,
				dataStoreService = mockData,
				memoryStoreService = mockMemory,
				lockShardCount = lockShardCount,
			})
		end

		beforeEach(function()
			mockData = MockDataStoreService.new()
			mockMemory = MockMemoryStoreService.new()
		end)

		it("uses the unsharded HashMap name when lockShardCount is omitted (backwards compat)", function()
			makeStore("bcompat")

			expect(mockMemory.hashMaps[`{Constants.LOCK_SCOPE}/bcompat`]).toBeDefined()
			for name in mockMemory.hashMaps do
				expect(string.find(name, "/s%d+of%d+$") == nil).toBe(true)
			end
		end)

		it("uses the unsharded HashMap name when lockShardCount = 1 (explicit)", function()
			makeStore("one", 1)
			expect(mockMemory.hashMaps[`{Constants.LOCK_SCOPE}/one`]).toBeDefined()
		end)

		it("creates N sharded HashMaps when lockShardCount >= 2", function()
			makeStore("sharded", 4)

			for i = 1, 4 do
				expect(mockMemory.hashMaps[`{Constants.LOCK_SCOPE}/sharded/s{i}of4`]).toBeDefined()
			end
			expect(mockMemory.hashMaps[`{Constants.LOCK_SCOPE}/sharded`]).toBeNil()
		end)

		it("rejects non-integer lockShardCount", function()
			expect(function()
				makeStore("bad", 2.5)
			end).toThrow()
		end)

		it("rejects lockShardCount <= 0 via t.numberPositive", function()
			expect(function()
				makeStore("bad", 0)
			end).toThrow()
		end)
	end)
end)
