--[=[
	@class hashMapRetry
	@private

	Provides a utility function to wrap Roblox MemoryStoreService HashMap API calls
	(like `GetAsync`, `SetAsync`, `UpdateAsync`) with automatic retries for specific,
	commonly transient error conditions identified by error message strings.

	**Purpose:** Similar to [dataStoreRetry], MemoryStore operations can fail due to
	temporary service issues, throttling, or internal errors. This module implements
	a retry mechanism with exponential backoff to handle these transient failures.
	It differs from [dataStoreRetry] by matching against error *strings* rather than
	numeric codes, as MemoryStore errors often manifest this way. It also includes
	a cancellation mechanism.

	**Usage:**
	```lua
	local MemoryStoreService = game:GetService("MemoryStoreService")
	local hashMapRetry = require(script.Parent.hashMapRetry)
	local myMap = MemoryStoreService:GetHashMap("MyMap")

	local handle = hashMapRetry(function()
		-- This function will be retried automatically on specific errors
		return myMap:GetAsync("MyKey")
	end)

	handle.promise:andThen(function(data)
		print("Successfully retrieved data:", data)
	end):catch(function(err)
		warn("Failed to get data after retries or cancelled:", err)
	end)

	-- To cancel the operation:
	-- handle.cancel()
	```
]=]

local Promise = require(script.Parent.Promise)
local Types = require(script.Parent.Types)

-- Maximum number of times to attempt the operation before giving up.
local MAX_RETRIES = 5

--[[
	List of error message substrings that indicate potentially transient MemoryStore
	errors worth retrying. These are based on observed errors and common failure modes
	like throttling and internal issues. Unlike DataStores, MemoryStore often reports
	errors via strings rather than distinct numeric codes.

	Refer to Roblox Creator Documentation for MemoryStore limits and potential issues:
	https://create.roblox.com/docs/cloud-services/memory-stores#observability
	(Note: Specific error message strings may not be exhaustively documented.)
]]
local RETRY_ERROR_CODES = {
	"TotalRequestsOverLimit", -- Exceeds universe-level request unit limit.
	"InternalError", -- Generic internal server error.
	"RequestThrottled", -- Recent MemoryStores requests hit one or more limits.
	"PartitionRequestsOverLimit", -- Exceeds partition request unit limit.
	"Throttled", -- Undocumented, included for completeness.
	"Timeout", -- Undocumented, included for completeness.
}

--[=[
	Wraps a function that performs a MemoryStore HashMap operation, automatically
	retrying it if it fails with specific transient error message substrings.

	Implements an exponential backoff strategy: waits 1s, 2s, 4s, 8s between retries.
	Includes a cancellation mechanism via the returned [RetryHandle].

	@within hashMapRetry
	@param func () -> any -- The function to execute and potentially retry. This function should perform the desired MemoryStore HashMap operation (e.g., `GetAsync`, `SetAsync`, `UpdateAsync`). It should return the result on success or throw an error on failure.
	@return RetryHandle<Promise<any>> -- A handle containing: `promise` (A Promise that resolves with the return value of `func` if it succeeds within `MAX_RETRIES` attempts) and `cancel` (A function that, when called, attempts to stop further retries and rejects the promise).
	@error string -- Rejects if `func` fails with a non-retriable error, if it fails with a retriable error `MAX_RETRIES` times, or if `cancel()` is called.
]=]
local function hashMapRetry(func: () -> any): Types.RetryHandle<Promise.TPromise<any>>
	local cancel = false

	local handle: Types.RetryHandle<Promise.TPromise<any>> = {
		promise = Promise.new(function(resolve, reject)
			local lastError
			for i = 1, MAX_RETRIES do
				-- Apply exponential backoff delay before retrying (starting from the second attempt)
				-- Only wait if the operation hasn't been cancelled.
				if i > 1 and not cancel then
					-- Wait times: 2^0=1s, 2^1=2s, 2^2=4s, 2^3=8s
					local retryAfter = 2 ^ (i - 1)
					task.wait(retryAfter)
				end

				if cancel then
					return reject(`HashMap error: operation cancelled`)
				end

				local result = table.pack(pcall(func)) -- { success: boolean, ...results | error: string }
				if result[1] == true then
					-- Success! Resolve the promise with the function's return values.
					return resolve(table.unpack(result, 2))
				end

				-- Failure. Store the error message.
				lastError = result[2]

				-- Check if the error message contains any of the retriable substrings.
				local retry = false
				for _, errorCodeSubstring in RETRY_ERROR_CODES do
					if lastError:find(errorCodeSubstring, 1, true) then
						retry = true
						break
					end
				end

				-- If the error is retriable, continue to the next iteration (if not cancelled).
				if retry then
					continue
				end

				-- Non-retriable error. Reject immediately.
				return reject(`HashMap error: {lastError}`)
			end
			-- If the loop completes, it means MAX_RETRIES were reached without success.
			-- Check for cancellation one last time before rejecting due to retries.
			if cancel then
				return reject(`HashMap error: operation cancelled`)
			else
				return reject(`HashMap error: too many retries ({MAX_RETRIES}). Last error: {lastError}`)
			end
		end),
		cancel = function()
			cancel = true
		end,
	}

	return handle
end

return hashMapRetry
