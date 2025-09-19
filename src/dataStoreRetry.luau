--[=[
	@class dataStoreRetry
	@private

	Provides a utility function to wrap Roblox DataStore API calls with automatic
	retries for specific, commonly transient error codes.

	**Purpose:** DataStore operations can sometimes fail due to temporary service issues,
	throttling, or internal errors. This module implements a retry mechanism with
	exponential backoff to increase the likelihood of success for operations that
	encounter these transient failures.

	**Usage:**
	```lua
	local DataStoreService = game:GetService("DataStoreService")
	local dataStoreRetry = require(script.Parent.dataStoreRetry)
	local myStore = DataStoreService:GetDataStore("MyStore")

	dataStoreRetry(function()
		-- This function will be retried automatically on specific errors
		return myStore:GetAsync("MyKey")
	end):andThen(function(data)
		print("Successfully retrieved data:", data)
	end):catch(function(err)
		warn("Failed to get data after retries:", err)
	end)
	```
]=]

local Promise = require(script.Parent.Promise)

-- Maximum number of times to attempt the operation before giving up.
local MAX_RETRIES = 5

--[[
	List of DataStore error codes that are considered potentially transient and
	worth retrying. These generally indicate temporary issues like internal server
	errors, throttling, or temporary unavailability.

	Refer to the Roblox Creator Documentation for details on specific DataStore error codes:
	https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
]]
local RETRY_ERROR_CODES = {
	-- 3xx: Throttling errors (indicating the request was throttled and dropped due to a full queue)
	301, -- 301: GetAsyncThrottle
	302, -- 302: SetAsyncThrottle
	303, -- 303: IncreAsyncThrottle
	304, -- 304: UpdateAsyncThrottle / TransformThrottle
	305, -- 305: GetSortedThrottle
	306, -- 306: RemoveAsyncThrottle

	-- 5xx: Server errors (most likely to be transient)
	500, -- 500: Undocumented, included for completeness.
	501, -- 501: InternalError - Can't parse response because data might be corrupted.
	502, -- 502: RequestRejected - Error occurred when processing on Roblox servers.
	503, -- 503: InternalError - Request was successful but key wasn't found.
	504, -- 504: InternalError - Request was successful but the response wasn't formatted correctly.
	505, -- 505: InternalError - OrderedDataStore request was successful but the response wasn't formatted correctly.
	-- Note: Other errors (e.g., 4xx permission errors, 1xx argument errors) are generally not transient
	-- and are not retried by default.
}

--[=[
	Wraps a function that performs a DataStore operation, automatically retrying it
	if it fails with specific transient error codes.

	Implements an exponential backoff strategy: waits 1s, 2s, 4s, 8s between retries.

	@within dataStoreRetry
	@param func () -> T -- The function to execute and potentially retry. This function should perform the desired DataStore operation (e.g., `GetAsync`, `SetAsync`, `UpdateAsync`). It should return the result of the operation on success or throw an error on failure.
	@return Promise<T> -- A Promise that resolves with the return value of `func` if it succeeds within `MAX_RETRIES` attempts.
	@error string -- Rejects with the error message if `func` fails with a non-retriable error code, or if it fails with a retriable error code `MAX_RETRIES` times.
]=]
local function dataStoreRetry<T>(func: () -> T): Promise.TPromise<T>
	return Promise.new(function(resolve, reject)
		local lastError -- Store the last retriable error encountered
		for i = 1, MAX_RETRIES do
			-- Apply exponential backoff delay before retrying (starting from the second attempt)
			if i > 1 then
				-- Wait times: 2^0=1s, 2^1=2s, 2^2=4s, 2^3=8s
				local retryAfter = 2 ^ (i - 1)
				task.wait(retryAfter)
			end

			-- Execute the provided function within a protected call
			local result = table.pack(pcall(func)) :: any -- { success: boolean, ...results | error: string }
			if result[1] == true then
				-- Success! Resolve the promise with the function's return values.
				return resolve(table.unpack(result, 2))
			end

			-- Failure. Extract the error message and attempt to parse the error code.
			local errorMessage = result[2]
			local errorCode = errorMessage:match("^(%d+):") -- Match code at the beginning (e.g., "502: API Services...")
			errorCode = if errorCode then tonumber(errorCode) else nil

			-- Check if the error code is in the list of retriable codes.
			if errorCode ~= nil and table.find(RETRY_ERROR_CODES, errorCode) then
				-- Retriable error. Store it and continue the loop for the next attempt.
				lastError = errorMessage
				continue
			else
				-- Non-retriable error or failed to parse code. Reject immediately.
				return reject(errorMessage)
			end
		end
		-- If the loop completes, it means MAX_RETRIES were reached without success.
		return reject(`DataStore error: too many retries ({MAX_RETRIES}). Last error: {lastError}`)
	end) :: any
end

return dataStoreRetry
