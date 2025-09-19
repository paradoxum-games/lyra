--[=[
	@class Files
	@private

	Handles the storage and retrieval of potentially large data blobs within Roblox DataStores,
	working around the size limitations imposed by DataStore `SetAsync`/`GetAsync` calls.

	**Core Problem:** Roblox DataStores have a maximum size limit per key (currently 4MB).
	Data that exceeds this limit cannot be stored directly.

	**Solution: Sharding & Compression**
	1.  **Sharding:** If the JSON-encoded data exceeds the configured `maxShardSize`, it is
	    split into multiple smaller chunks (shards). Metadata about these shards (a unique
	    shard ID and the total shard count) is stored in the primary DataStore entry for the
	    original key, while the actual shard data is stored under separate keys derived from
	    the shard ID.
	2.  **Compression:** Before sharding, the JSON-encoded data is converted to binary using
	    `buffer.fromstring`. This binary representation is then JSON-encoded *again* before
	    being split into shards. Roblox automatically compresses buffers when encoding them
		using `JSONEncode`. This helps reduce the number of shards required, minimizing
		DataStore requests.

	**Shard Key Naming:** Shard data is stored using keys formatted as `{shardId}-{shardIndex}`,
	where `shardId` is a unique GUID generated for the file and `shardIndex` is the 1-based
	index of the shard.
]=]

local HttpService = game:GetService("HttpService")

local Types = require(script.Parent.Types)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)
local dataStoreRetry = require(script.Parent.dataStoreRetry)

--[=[
	Splits a string into chunks of a specified size.
	Used for sharding large data blobs into smaller pieces.

	@within Files
	@param str string -- The string to be split.
	@param chunkSize number -- The size of each chunk.
	@return { string } -- A table containing the split chunks.
]=]
local function splitString(str: string, chunkSize: number): { string }
	local numChunks = math.ceil(#str / chunkSize)
	local chunks = {}
	for i = 1, numChunks do
		local start = (i - 1) * chunkSize + 1
		local chunk = string.sub(str, start, start + chunkSize - 1)
		table.insert(chunks, chunk)
	end
	return chunks
end

--[=[
	Checks if a file object represents a sharded file (i.e., data stored across multiple keys).

	@within Files
	@param file File -- The file object to check.
	@return boolean -- True if the file is sharded, false otherwise.
]=]
local function isLargeFile(file: Types.File): boolean
	return file.shard ~= nil
end

--[=[
	@within Files
	Parameters required for the `write` function.

	@interface WriteParams
	.store DataStore -- The DataStore instance to write to.
	.data any -- The Luau data to be stored. Must be JSON-encodable.
	.maxShardSize number -- The maximum size (in bytes) allowed for a single shard. Data exceeding this size after initial JSON encoding will trigger the sharding process.
	.key string -- The primary key under which the file metadata (or the full data if not sharded) will be conceptually associated. This key is *not* directly used for storing shards.
	.userIds { number }? -- An optional array of UserIDs for DataStore tagging.
]=]
export type WriteParams = {
	store: DataStore,
	data: any,
	maxShardSize: number,
	key: string, -- Primarily for context/logging, not direct shard storage key
	userIds: { number }?,
}

--[=[
	@interface WriteError
	@within Files
	Structure representing an error encountered during the `write` operation.

	.error string -- A string describing the error.
	.file File -- The file metadata that was being processed when the error occurred. This is used for cleanup operations if shards were partially written.
]=]
export type WriteError = {
	error: string,
	file: Types.File,
}

--[=[
	Writes data to the DataStore, automatically handling sharding and compression if necessary.

	If the JSON-encoded data is smaller than `maxShardSize`, it's stored directly within the
	returned [File] object (in the `data` field).

	If the data is larger, it's compressed, sharded, and stored across multiple DataStore keys.
	The returned [File] object will contain `shard` (the unique ID for the shards) and
	`count` (the number of shards) instead of the `data` field.

	@within Files
	@param params WriteParams -- The parameters for the write operation.
	@return Promise<File> -- A Promise that resolves with a [File] object representing the stored data (either directly containing the data or shard metadata).
	@error WriteError -- Rejects with a `WriteError` if any shard fails to write.
	@error string -- Propagates errors from `DataStore:SetAsync` via `dataStoreRetry`.
]=]
local function write(params: WriteParams): Promise.TPromise<Types.File>
	-- Step 1: Initial JSON encode to check size against the limit.
	local dataEncoded = HttpService:JSONEncode(params.data)
	if #dataEncoded <= params.maxShardSize then
		-- Data fits within a single shard, no sharding needed. Return directly.
		return Promise.resolve({ data = params.data } :: Types.File)
	end

	-- Step 2: Convert the JSON-encoded data to a binary buffer.
	-- This binary buffer is then JSON encoded *again*, which Roblox automatically compresses.
	-- This helps reduce the size of the data before sharding.
	local dataCompressed = HttpService:JSONEncode(buffer.fromstring(dataEncoded))

	-- Step 3: Split the compressed, double-encoded string into shards.
	local shards = splitString(dataCompressed, params.maxShardSize)

	-- Step 4: Generate metadata for the sharded file.
	local shardId = HttpService:GenerateGUID(false) -- Unique ID for this set of shards.
	local file = { shard = shardId, count = #shards } -- File object containing shard info.

	-- Step 5: Write each shard to the DataStore using derived keys.
	local shardPromises = Tables.map(shards, function(shard, index)
		-- Key format: {shardId}-{shardIndex} (1-based index)
		local shardKey = `{shardId}-{index}`
		return dataStoreRetry(function()
			-- Attempt to write the individual shard with retry logic.
			return params.store:SetAsync(shardKey, shard, params.userIds)
		end)
	end)

	-- Step 6: Wait for all shard writes to complete.
	return Promise
		.all(shardPromises)
		:andThenReturn(file) -- If all succeed, return the file metadata.
		:catch(function(err)
			-- If any shard write fails, reject the promise with detailed error info.
			return Promise.reject({
				error = `Failed to write file: {err}`,
				file = file, -- Include file metadata for cleanup.
			} :: WriteError)
		end)
end

--[=[
	@interface ReadParams
	@within Files
	Parameters required for the `read` function.

	.store DataStore -- The DataStore instance to read from.
	.file File -- The [File] object obtained from a previous `write` operation or retrieved from the primary DataStore key. This object determines whether to read directly or reconstruct from shards.
]=]
export type ReadParams = {
	store: DataStore,
	file: Types.File,
}

--[=[
	Reads data from the DataStore, automatically handling reconstruction from shards if necessary.

	If the provided `file` object contains the `data` field directly, it returns that data.
	If the `file` object contains `shard` and `count` fields, it reads all corresponding shards
	from the DataStore, concatenates them, decompresses the result, and returns the original data.

	@within Files
	@param params ReadParams -- The parameters for the read operation.
	@return Promise<any> -- A Promise that resolves with the original data.
	@error string -- Rejects with an error message string if any shard is missing or if decoding/decompression fails. Propagates errors from `DataStore:GetAsync` via `dataStoreRetry`.
]=]
local function read(params: ReadParams): Promise.TPromise<any>
	-- Step 1: Check if the file is sharded.
	if not isLargeFile(params.file) then
		-- Not sharded, data is stored directly in the file object.
		return Promise.resolve(params.file.data)
	end

	-- Step 2: Prepare to read shards.
	local shardId = params.file.shard
	assert(shardId, "Shard ID missing from large file object") -- Should be guaranteed by isLargeFile
	local shardCount = params.file.count
	assert(shardCount, "Shard count missing from large file object")

	local promises = {}

	-- Step 3: Create promises to fetch each shard.
	for i = 1, shardCount do
		local shardKey = `{shardId}-{i}`
		table.insert(
			promises,
			dataStoreRetry(function()
				-- Attempt to read the individual shard with retry logic.
				return params.store:GetAsync(shardKey)
			end)
		)
	end

	-- Step 4: Wait for all shard reads to complete.
	return Promise.all(promises):andThen(function(shards)
		-- Step 5: Validate that all shards were retrieved.
		for i = 1, shardCount do
			if shards[i] == nil then
				-- A shard is missing, cannot reconstruct the file.
				return Promise.reject(`Missing shard {i} for file (shardId: {shardId})`)
			end
		end

		-- Step 6: Concatenate and decode the compressed data (first JSON decode, decompresses).
		-- This reverses the double JSON encoding done during the write process.
		local ok, compressedData = pcall(function()
			return HttpService:JSONDecode(table.concat(shards))
		end)
		if not ok then
			return Promise.reject(`Error decoding compressed file data (shardId: {shardId}): {compressedData}`) -- compressedData contains error msg here
		end
		if typeof(compressedData) ~= "buffer" then
			return Promise.reject(
				`Expected buffer after first decode, got {typeof(compressedData)} (shardId: {shardId})`
			)
		end

		-- Step 7: Convert the buffer back to a string and decode the original JSON data.
		local ok2, originalData = pcall(function()
			return HttpService:JSONDecode(buffer.tostring(compressedData))
		end)
		if not ok2 then
			return Promise.reject(`Error decoding original file data (shardId: {shardId}): {originalData}`) -- originalData contains error msg here
		end

		return originalData -- Successfully reconstructed original data.
	end)
	-- No explicit :catch here, errors from GetAsync (via retry) or rejections above will propagate.
end

return {
	isLargeFile = isLargeFile,
	write = write,
	read = read,
}
