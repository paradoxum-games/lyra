--[=[
	@class Constants
	@private

	Module containing constant values used throughout the Lyra library.
]=]

-- Estimated bytes reserved within the DataStore value for Lyra's internal metadata
-- (like appliedMigrations, orphanedFiles list, and File object overhead when sharded).
-- This ensures that the actual user data shards stay safely within the DataStore limits.
local INTERNAL_SPACE_RESERVE_BYTES = 10_000

--[=[
	@interface Constants
	@within Constants

	.RECORD_SCOPE "lyra/records" -- Scope prefix used for keys storing the main DataStoreRecord objects.

	.TX_SCOPE "lyra/tx" -- Scope prefix used for keys storing transaction status markers in a DataStore.

	.SHARD_SCOPE "lyra/shards" -- Scope prefix used for keys storing data shards in a DataStore.

	.LOCK_SCOPE "lyra/locks" -- Scope prefix used for keys storing lock information in a MemoryStore HashMap.

	.MAX_CHUNK_SIZE number -- Maximum size (in bytes) for a single data shard stored in DataStore. Derived from the Roblox DataStore value limit (4MB) minus a reserved amount (INTERNAL_SPACE_RESERVE_BYTES) for Lyra's internal metadata within the main record.

	.LOCK_REFRESH_INTERVAL_SECONDS number -- How often (in seconds) a held lock should be refreshed in MemoryStore to prevent it from expiring while still actively being used. Should be significantly shorter than LOCK_DURATION_SECONDS.

	.LOCK_DURATION_SECONDS number -- The initial time-to-live (TTL) duration (in seconds) for a lock acquired in MemoryStore. If the lock isn't refreshed within this time, it will automatically expire. Must be longer than LOCK_REFRESH_INTERVAL_SECONDS to allow time for refreshes.

	.AUTOSAVE_INTERVAL_SECONDS number -- How often (in seconds) the automatic saving mechanism should attempt to save dirty session data.
]=]
local Constants = {
	RECORD_SCOPE = "lyra/records",
	TX_SCOPE = "lyra/tx",
	SHARD_SCOPE = "lyra/shards",
	LOCK_SCOPE = "lyra/locks",

	MAX_CHUNK_SIZE = 4_000_000 - INTERNAL_SPACE_RESERVE_BYTES,

	LOCK_REFRESH_INTERVAL_SECONDS = 60,

	LOCK_DURATION_SECONDS = 90,

	AUTOSAVE_INTERVAL_SECONDS = 5 * 60, -- 5 minutes
}

return Constants
