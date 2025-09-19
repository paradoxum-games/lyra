--[=[
	Implements a distributed locking mechanism using Roblox's MemoryStoreService.
	This allows coordinating access to shared resources (like DataStore keys)
	across different game servers or instances.

	The locking strategy involves:
	- Attempting to atomically acquire a lock using `MemoryStoreService:UpdateAsync`.
	- Setting a Time-To-Live (TTL) on the lock key in MemoryStore.
	- Periodically refreshing the lock's TTL in a background task to maintain ownership.
	- Providing a mechanism (`onLockLost`) to notify the holder if the lock refresh fails
	  or the lock expires unexpectedly.

	This ensures that typically only one process holds the lock for a given key at a time.

	@class Locks
	@private
]=]

local HttpService = game:GetService("HttpService")

-- Small buffer subtracted from the TTL when calculating the local expiry time.
-- This helps account for potential clock skew or network latency, reducing the
-- chance of the local check (`isLocked`) returning true after the lock has
-- actually expired in MemoryStore.
local LOCK_TTL_ERROR_MARGIN_SECS = 0.2

local Types = require(script.Parent.Types)
local Promise = require(script.Parent.Promise)
local hashMapRetry = require(script.Parent.hashMapRetry)

--[=[
	Possible states of the lock acquisition and holding process.
	@type LockStatus "acquiring" | "held" | "released"
	@within Locks
	@tag enum
	@private
]=]
type LockStatus = "acquiring" | "held" | "released"

--[=[
	Represents an acquired lock handle, providing methods to interact with the lock.

	@interface LockHandle
	@within Locks
	.release () -> Promise -- Releases the lock immediately. Stops the refresh loop and attempts to clear the lock key in MemoryStore (by setting TTL to 0). Resolves when the release attempt is complete.
	.isLocked () -> boolean -- Checks if the lock is currently considered held locally. This checks both the internal status and compares the last confirmed expiry time (from MemoryStore) against the current local time. True if the lock is believed to be held.
	.onLockLost (() -> ()) -> (() -> ()) -- Registers a callback function to be invoked if the lock is lost unexpectedly (e.g., refresh fails, TTL expires). Returns a function to disconnect/unregister the callback.
]=]
export type LockHandle = {
	release: () -> Promise.Promise,
	isLocked: () -> boolean,
	onLockLost: (callback: () -> ()) -> () -> (),
}

--[=[
	Parameters for acquiring a lock.

	@interface AcquireLockParams
	@within Locks
	.storeContext Types.StoreContext<any> -- Shared store context containing logger and MemoryStoreHashMap instance.
	.key string -- The unique key identifying the resource to be locked.
	.duration number -- The duration (TTL) in seconds for which the lock should be held/refreshed.
	.refreshInterval number -- The interval in seconds at which the lock refresh should be attempted.
]=]
export type AcquireLockParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
	duration: number,
	refreshInterval: number,
}

--[=[
	Attempts to acquire a distributed lock for the specified key.

	Manages the lock acquisition process, including retries with exponential
	backoff, setting up the background refresh loop, and providing a LockHandle
	on success.

	@param params -- Configuration for the lock acquisition.
	@return Promise<LockHandle> -- Resolves with a LockHandle if the lock is acquired successfully.
	@error Rejects if the lock cannot be acquired within the specified duration/attempts, or if other MemoryStore errors occur.
	@within Locks
]=]
local function acquireLock(params: AcquireLockParams): Promise.TPromise<LockHandle>
	-- Unique identifier for this specific lock attempt/instance.
	local lockId = HttpService:GenerateGUID(false)
	-- List of callbacks to invoke if the lock is lost.
	local expiredCallbacks: { () -> () } = {}
	-- Handle for the `task.delay` used to trigger expiry callbacks locally.
	local expiryThread: thread? = nil
	-- Promise representing the background refresh loop.
	local refreshPromise: Promise.Promise? = nil

	-- Current state of the lock.
	local status: LockStatus
	-- The local time (`os.clock()`) when the lock is expected to expire based on the
	-- last successful `UpdateAsync` call, minus the error margin.
	local lastConfirmedExpiry: number? = nil

	local ctx = params.storeContext
	local key = params.key
	local logger = ctx.logger:extend({ method = "acquireLock", key = key, lockId = lockId })

	--[=[
		Helper function to update the internal lock status and log the transition.
		@param newStatus -- The new status to set.
		@within Locks
		@private
	]=]
	local function transitionTo(newStatus: LockStatus)
		logger:log("trace", `lock transition: {status or "nil"} -> {newStatus}`)
		status = newStatus
	end

	--[=[
		Invokes all registered `onLockLost` callbacks.
		Called when the local expiry timer (`expiryThread`) fires or when refresh fails.
		@within Locks
		@private
	]=]
	local function spawnExpiryCallbacks()
		-- Only spawn if still considered 'held' locally to avoid duplicate calls after release.
		if status == "held" then
			logger:log("warn", "lock expiry timer fired or refresh failed, invoking onLockLost callbacks")
			transitionTo("released")
			for _, callback in expiredCallbacks do
				task.spawn(callback)
			end
		end
	end

	--[=[
		Attempts to update the lock key in MemoryStore using UpdateAsync.
		This is used for initial acquisition, refresh, and release (with ttl=0).

		The transform function ensures atomicity:
		- If the key doesn't exist (`otherLockId == nil`), set it to our `lockId`.
		- If the key exists and holds our `lockId`, update the TTL (refresh).
		- If the key exists and holds a different `lockId`, do nothing (fail acquisition/refresh).

		Also manages the local expiry timer (`expiryThread`) based on successful updates.

		@param ttl -- The Time-To-Live in seconds for the UpdateAsync call.
		@return Types.RetryHandle<Promise<any>> -- Handle containing the promise and cancel function from `hashMapRetry`.
		@within Locks
		@private
	]=]
	local function tryUpdate(ttl: number): Types.RetryHandle<Promise.TPromise<any>>
		logger:log("trace", `attempting UpdateAsync on key '{key}' with ttl {ttl}`)

		-- Transform function for atomic update
		local function transformFunction(otherLockId: string?): string?
			if otherLockId == nil or otherLockId == lockId then
				-- Key is empty or already held by us, allow update/acquisition.
				return lockId
			end
			-- Key is held by someone else, prevent update. UpdateAsync returns nil.
			return nil
		end

		-- Wrap the MemoryStore call in retry logic
		local retryHandle = hashMapRetry(function()
			return ctx.lockHashMap:UpdateAsync(key, transformFunction, ttl)
		end)

		-- Side effects on successful update
		retryHandle.promise:tap(function(value)
			-- `value` will be `lockId` if UpdateAsync succeeded, `nil` otherwise.
			if value ~= nil then
				-- Update local expiry time based on successful MemoryStore update.
				lastConfirmedExpiry = os.clock() + ttl - LOCK_TTL_ERROR_MARGIN_SECS
				logger:log("trace", `UpdateAsync succeeded, lastConfirmedExpiry updated to {lastConfirmedExpiry}`)

				-- Cancel any existing expiry timer thread.
				if expiryThread then
					task.cancel(expiryThread)
				end

				-- If TTL > 0 (acquisition/refresh), start a new local timer.
				-- If TTL is 0 (release), don't start a timer.
				if ttl > 0 then
					logger:log("trace", `starting local expiry timer for {ttl} seconds`)
					expiryThread = task.delay(ttl, spawnExpiryCallbacks)
				end
			else
				logger:log("trace", `UpdateAsync failed or returned nil (lock held by another?)`)
			end
		end)

		return retryHandle
	end

	--[=[
		Releases the lock. Stops refresh/expiry timers and attempts to clear the
		lock in MemoryStore by setting TTL to 0.

		@return Promise -- Resolves when the release process is complete.
		@within Locks
		@private
	]=]
	local function release(): Promise.Promise
		logger:log("trace", "release function called")

		-- Idempotency check: only proceed if currently 'held'.
		if status ~= "held" then
			logger:log("trace", `lock not 'held' (status: {status}), skipping release logic`)
			return Promise.resolve()
		end
		transitionTo("released")

		-- Cancel local expiry timer.
		if expiryThread then
			task.cancel(expiryThread)
			expiryThread = nil
			logger:log("trace", "cancelled expiryThread")
		end

		-- Cancel background refresh loop.
		if refreshPromise then
			refreshPromise:cancel()
			refreshPromise = nil
			logger:log("trace", "cancelled refreshPromise")
		end

		-- Check if the lock is likely still valid in MemoryStore before trying to clear it.
		local isLikelyAcquiredRemotely = lastConfirmedExpiry and lastConfirmedExpiry > os.clock()
		if isLikelyAcquiredRemotely then
			logger:log("trace", "attempting to clear lock in MemoryStore (UpdateAsync with TTL 0)")
			-- Attempt to set TTL to 0. We don't need to wait for this promise to resolve fully,
			-- but we return it so the caller can wait if needed.
			return tryUpdate(0).promise:catch(function(err)
				logger:log("warn", "failed during final UpdateAsync(ttl=0) on release", { error = err })
				return Promise.reject(err) -- Pass through the error if needed
			end)
		else
			logger:log("trace", "lock likely already expired remotely, skipping final UpdateAsync")
			return Promise.resolve()
		end
	end

	--[=[
		Main loop for attempting to acquire the lock initially.
		Uses `tryUpdate` with exponential backoff.

		@return Promise -- Resolves when the lock is acquired, rejects if timeout occurs.
		@within Locks
		@private
	]=]
	local function waitForLock(): Promise.Promise
		logger:log("trace", "entering waitForLock loop")
		transitionTo("acquiring")

		local acquisitionStartTime = os.clock()
		local currentRetryHandle: Types.RetryHandle<Promise.TPromise<any>>? = nil
		local attemptCount = 0
		local maxAcquisitionTime = params.duration -- Use lock duration as acquisition timeout

		return Promise.new(function(resolve, reject, onCancel)
			-- Setup cancellation handler: clean up any pending retry and release the lock.
			onCancel(function()
				logger:log("trace", "waitForLock cancelled")
				local cleanupPromise = Promise.resolve()
				if currentRetryHandle then
					currentRetryHandle.cancel()
					-- The retry may have an in-flight request. To prevent race
					-- conditions, we only release after it settles.
					cleanupPromise = (currentRetryHandle :: any).promise
				end

				-- After potential retry settles, attempt release.
				cleanupPromise:finally(function()
					release():catch(function(err)
						-- Log release errors during cancellation but don't reject for them.
						logger:log("error", "failed to release lock during cancellation", { error = err })
					end)
				end)
			end)

			-- Run the acquisition loop in a separate thread to allow
			-- cancellation without abruptly stopping via coroutine.close.
			task.spawn(function()
				while (os.clock() - acquisitionStartTime) < maxAcquisitionTime do
					-- Check for cancellation at the start of each attempt.
					if onCancel() then
						logger:log("trace", "detected cancellation within loop")
						return -- Exit loop if cancelled
					end

					attemptCount += 1
					logger:log("trace", `acquisition attempt {attemptCount}`)
					currentRetryHandle = tryUpdate(params.duration)
					-- Await the result of the UpdateAsync attempt (wrapped in retry logic)
					local resolved, value = (currentRetryHandle :: any).promise:await()
					currentRetryHandle = nil -- Clear handle once settled

					if resolved and value ~= nil then
						-- Success! Lock acquired.
						logger:log("info", "lock acquired successfully")
						transitionTo("held")
						return resolve() -- Resolve the main acquireLock promise
					elseif not resolved then
						-- UpdateAsync (or retry logic) failed. Log warning.
						logger:log("warn", "attempt to acquire lock failed", {
							attemptCount = attemptCount,
							error = value, -- Error message from rejection
						})
						-- Continue loop if error is deemed retryable by hashMapRetry
					else
						-- UpdateAsync succeeded but returned nil (lock held by someone else).
						logger:log("trace", "lock currently held by another instance")
						-- Continue loop to retry.
					end

					-- Check for cancellation again after the attempt.
					if onCancel() then
						logger:log("trace", "detected cancellation after attempt")
						return -- Exit loop if cancelled
					end

					-- Exponential backoff before next attempt, capped at 30s.
					local retryAfter = math.min(2 ^ (attemptCount - 1), 30)
					logger:log("trace", `waiting {retryAfter}s before next attempt`)
					task.wait(retryAfter)
				end

				-- Loop finished without acquiring the lock within the time limit.
				logger:log("error", "failed to acquire lock within time limit", { duration = maxAcquisitionTime })
				return reject(`Failed to acquire lock for key '{key}' within {maxAcquisitionTime} seconds`)
			end)
		end)
	end

	--[=[
		Starts the background loop responsible for periodically refreshing the lock TTL.
		@within Locks
		@private
	]=]
	local function setupLockRefresh(): ()
		logger:log("trace", "setting up background lock refresh loop")

		local currentRefreshHandle: Types.RetryHandle<Promise.TPromise<any>>? = nil

		-- Create a promise representing the refresh loop's lifetime.
		refreshPromise = Promise.new(function(resolveLoop, _, onCancelLoop)
			-- Setup cancellation for the refresh loop promise itself.
			onCancelLoop(function()
				logger:log("trace", "refreshPromise cancelled")
				-- If a refresh attempt is in progress, cancel its retry handle.
				if currentRefreshHandle then
					currentRefreshHandle.cancel()
				end
			end)

			-- Run the refresh loop in a separate thread to allow
			-- cancellation without abruptly stopping via coroutine.close.
			task.spawn(function()
				-- Continue looping as long as the lock is considered 'held'.
				while status == "held" do
					-- Wait for the specified refresh interval.
					task.wait(params.refreshInterval)

					-- Check for cancellation or status change during the wait.
					if onCancelLoop() or status ~= "held" then
						logger:log("trace", "exiting refresh loop due to cancellation or status change")
						break
					end

					logger:log("trace", "attempting lock refresh")
					-- Attempt to update the lock TTL using tryUpdate.
					currentRefreshHandle = tryUpdate(params.duration)
					-- Await the result of the refresh attempt
					local resolved, value = (currentRefreshHandle :: any).promise:await()
					currentRefreshHandle = nil -- Clear handle once settled

					-- Check status again after the refresh attempt.
					if status ~= "held" then
						logger:log("trace", "exiting refresh loop, status changed during refresh attempt")
						break
					end

					-- If refresh failed (rejected or returned nil), the lock is lost.
					if not resolved or value == nil then
						logger:log("warn", "failed to refresh lock, lock considered lost", { error = value })
						-- Trigger expiry callbacks and exit the loop.
						spawnExpiryCallbacks()
						break
					else
						logger:log("trace", "lock refreshed successfully")
					end
				end

				-- Loop exited (either normally due to status change/cancellation, or due to refresh failure).
				logger:log("trace", "background refresh loop finished")
				resolveLoop() -- Resolve the main refreshPromise.
			end)
		end)
	end

	-- Construct the LockHandle object to be returned.
	local lockHandle: LockHandle = {
		release = release,
		isLocked = function(): boolean
			-- Check both internal status and local expiry time.
			return status == "held" and (lastConfirmedExpiry or 0) > os.clock()
		end,
		onLockLost = function(callback: () -> ()): () -> ()
			-- Add callback to the list.
			table.insert(expiredCallbacks, callback)
			-- Return a function to remove the callback from the list.
			return function()
				local idx = table.find(expiredCallbacks, callback)
				if idx then
					table.remove(expiredCallbacks, idx)
				end
			end
		end,
	}

	-- Chain the acquisition and refresh setup.
	return waitForLock() -- Attempt initial acquisition.
		:andThen(function()
			-- If acquisition succeeded, set up the refresh loop and return the handle.
			setupLockRefresh()
			return lockHandle
		end)
		:catch(function(err)
			-- If acquisition failed, attempt to release any partially acquired state
			-- and then re-reject with the original error.
			logger:log("error", "failed to acquire lock", { error = err })
			return release():andThen(function()
				-- Ensure the original error propagates.
				return Promise.reject(err)
			end)
		end)
end

--[=[
	Parameters for probing if a lock is active.

	@interface ProbeLockActiveParams
	@within Locks
	.storeContext Types.StoreContext<any> -- Shared store context containing logger and MemoryStoreHashMap instance.
	.key string -- The unique key identifying the resource to be locked.
]=]
export type ProbeLockActiveParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
}

--[=[
	Checks if a lock key currently exists in MemoryStore without attempting to acquire it.
	Useful for determining if another process likely holds the lock.

	Note: This is a point-in-time check and doesn't guarantee the lock state won't
	change immediately after the check completes.

	@param params -- Parameters for probing the lock.
	@return Promise<boolean> -- Resolves with true if the lock key exists, false otherwise.
	@within Locks
]=]
local function probeLockActive(params: ProbeLockActiveParams): Promise.TPromise<boolean>
	local ctx = params.storeContext
	local key = params.key
	local logger = ctx.logger:extend({ method = "probeLockActive", key = key })

	logger:log("trace", "probing if lock is active via GetAsync")

	-- Use GetAsync wrapped in retry logic.
	local retryHandle = hashMapRetry(function()
		return ctx.lockHashMap:GetAsync(key)
	end)

	-- Check if the GetAsync call returned a value (meaning the key exists).
	return retryHandle.promise:andThen(function(value)
		local isActive = value ~= nil
		logger:log("trace", `probe result: {isActive}`)
		return isActive
	end)
end

return {
	acquireLock = acquireLock,
	probeLockActive = probeLockActive,
}
