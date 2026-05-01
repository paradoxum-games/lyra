--[=[
	@class ShardedHashMap
	@private

	A thin facade over multiple `MemoryStoreHashMap` instances that routes each
	operation to a shard based on a hash of the key. Used by `Store` when a user
	opts into sharded locking via `lockShardCount`, letting a store spread its
	lock traffic across N HashMaps instead of one — each HashMap has its own
	partition throughput budget.

	The facade exposes the subset of the `MemoryStoreHashMap` interface used by
	`Locks.luau` (`UpdateAsync`, `GetAsync`, `RemoveAsync`), so existing call
	sites work unchanged.
]=]

-- Rotate-xor over bytes. Uses only bit32 ops to avoid losing precision past
-- 2^53, which FNV-1a's `* 16777619` step hits in Luau doubles.
local function hashKey(s: string): number
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(bit32.lrotate(h, 5), string.byte(s, i))
	end
	return h
end

local function pickShard(key: string, count: number): number
	return (hashKey(key) % count) + 1
end

export type ShardedHashMap = {
	_shards: { MemoryStoreHashMap },
	_count: number,

	UpdateAsync: (
		self: ShardedHashMap,
		key: string,
		transform: (any, any) -> any,
		ttl: number
	) -> any,
	GetAsync: (self: ShardedHashMap, key: string) -> any,
	RemoveAsync: (self: ShardedHashMap, key: string) -> (),
}

local ShardedHashMap = {}
ShardedHashMap.__index = ShardedHashMap

--[=[
	Shards are named `{baseName}/s{i}of{shardCount}` (1-based). Embedding
	`shardCount` in the name means shard 1 of 4 is a different namespace from
	shard 1 of 8 — so bumping shardCount doesn't alias old keys onto new
	shards.

	@param shardCount -- Must be an integer >= 2. shardCount == 1 should skip this facade entirely in the caller.
]=]
local function new(
	memoryStoreService: MemoryStoreService,
	baseName: string,
	shardCount: number
): ShardedHashMap
	assert(shardCount >= 2 and shardCount == math.floor(shardCount), "shardCount must be an integer >= 2")

	local shards = table.create(shardCount) :: { MemoryStoreHashMap }
	for i = 1, shardCount do
		shards[i] = memoryStoreService:GetHashMap(`{baseName}/s{i}of{shardCount}`)
	end

	local self = setmetatable({
		_shards = shards,
		_count = shardCount,
	}, ShardedHashMap)

	return (self :: any) :: ShardedHashMap
end

function ShardedHashMap.UpdateAsync(
	self: ShardedHashMap,
	key: string,
	transform: (any, any) -> any,
	ttl: number
): any
	local shard = self._shards[pickShard(key, self._count)]
	return shard:UpdateAsync(key, transform, ttl)
end

function ShardedHashMap.GetAsync(self: ShardedHashMap, key: string): any
	local shard = self._shards[pickShard(key, self._count)]
	return shard:GetAsync(key)
end

function ShardedHashMap.RemoveAsync(self: ShardedHashMap, key: string)
	local shard = self._shards[pickShard(key, self._count)]
	shard:RemoveAsync(key)
end

return {
	new = new,
	hashKey = hashKey,
	pickShard = pickShard,
}
