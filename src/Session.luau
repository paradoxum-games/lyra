--[=[
	Manages the in-memory state and persistence lifecycle for a single data key
	within a Store. A Session represents an active, locked instance of a key's
	data, coordinating data loading, saving, updates, transactions, migrations,
	and cleanup.

	Sessions are created internally by [Store:load] after acquiring a distributed
	lock via the Locks module. They handle:
	- Loading initial data by reading the main record, file shards, and pending
	  transactions, applying migrations, or importing legacy data.
	- Providing access to the current data ([Session:get]).
	- Applying mutations ([Session:update]) safely within a `noYield` context and
	  tracking changes.
	- Saving changes back to DataStores ([Session:save], [Session:updateRecord], [Session:writeRecord]),
	  potentially sharding large data via the Files module.
	- Coordinating multi-key transactions ([Store:tx] interacts with Session state).
	- Automatically saving data periodically ([Session:startAutosaving]).
	- Cleaning up orphaned file shards in the background ([Session:orphanFile]).
	- Gracefully unloading data ([Session:unload]), ensuring final saves and lock release.

	A Session is intrinsically tied to a [Locks.LockHandle]. If the lock is lost,
	the Session becomes 'closed' and unusable, triggering cleanup.

	@class Session
	@private
]=]

local HttpService = game:GetService("HttpService")

local Constants = require(script.Parent.Constants)
local Files = require(script.Parent.Files)
local Locks = require(script.Parent.Locks)
local Log = require(script.Parent.Log)
local Migrations = require(script.Parent.Migrations)
local PromiseQueue = require(script.Parent.PromiseQueue)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)
local t = require(script.Parent.Parent.t)
local Types = require(script.Parent.Types)
local Transactions = require(script.Parent.Transactions)
local dataStoreRetry = require(script.Parent.dataStoreRetry)
local noYield = require(script.Parent.noYield)

--[=[
	Internal type definition for Session methods (used for metatable).

	@interface SessionImpl<T>
	@within Session
	@private
	.__index SessionImpl<T> -- Metatable self-reference.

	-- Static method to load data and create a session
	.load (params: LoadSessionParams<T>) -> Promise<Session<T>>

	-- Internal methods for saving data
	.updateRecord (self: Session<T>) -> Promise<any>
	.orphanFile (self: Session<T>, file: Types.File) -> ()
	.writeRecord (self: Session<T>, txInfo: Types.TxInfo) -> Promise<any>

	-- State checking
	.isSaved (self: Session<T>) -> boolean

	-- Internal state mutation
	.setData (self: Session<T>, data: T) -> ()
	.mutateKey (self: Session<T>, newData: T) -> ()

	-- Autosave management
	.startAutosaving (self: Session<T>) -> ()
	.stopAutosaving (self: Session<T>) -> ()

	-- Public API methods (called via Store)
	.unload (self: Session<T>) -> Promise
	.get (self: Session<T>) -> Promise<T>
	.update (self: Session<T>, transformFunction: (data: T) -> boolean) -> Promise<boolean>
	.save (self: Session<T>) -> Promise
]=]
type SessionImpl<T> = {
	__index: SessionImpl<T>,
	load: (params: LoadSessionParams<T>) -> Promise.TPromise<Session<T>>,
	updateRecord: (self: Session<T>) -> Promise.TPromise<any>,
	orphanFile: (self: Session<T>, file: Types.File) -> (),
	writeRecord: (self: Session<T>, txInfo: Types.TxInfo) -> Promise.TPromise<any>,
	isSaved: (self: Session<T>) -> boolean,
	setData: (self: Session<T>, data: T) -> (),
	mutateKey: (self: Session<T>, newData: T) -> (),
	startAutosaving: (self: Session<T>) -> (),
	stopAutosaving: (self: Session<T>) -> (),
	unload: (self: Session<T>) -> Promise.Promise,
	get: (self: Session<T>) -> Promise.TPromise<T>,
	update: (self: Session<T>, transformFunction: (data: T) -> boolean) -> Promise.TPromise<boolean>,
	updateImmutable: (self: Session<T>, transformFunction: (data: T) -> T | false) -> Promise.TPromise<boolean>,
	save: (self: Session<T>) -> Promise.Promise,
}

--[=[
	Internal state properties of a Session instance.

	@interface SessionProps<T>
	@within Session
	@private
	._cleanupAutosave (() -> ())? -- Function to stop the running autosave loop, if active.

	.key string -- The unique key this session manages.
	.ctx Types.StoreContext<T> -- Shared context from the parent Store.
	.lockHandle Locks.LockHandle -- The active distributed lock handle for this key.

	.userIds { number }? -- User IDs associated with this session (primarily for SetAsync).

	.data T? -- The current, mutable in-memory data.
	.appliedMigrations { string } -- List of migration step names already applied to this data.

	.changeSet { [string]: true } -- Tracks unsaved changes. Keys are unique mutation IDs, value is always true. Cleared on successful save.

	.orphanedFiles { Types.File } -- List of file shards (from previous saves) marked for deletion.
	.currentFile Types.File? -- Reference to the current file structure (potentially sharded) representing the saved state.
	.queue PromiseQueue.PromiseQueue -- PromiseQueue to serialize save/unload/tx operations for this key.
	.txLockPromise Promise? -- A promise used during multi-key transactions (`Store:tx`) to block concurrent `Session:update` calls on this key until the transaction completes.

	.closed boolean -- Flag indicating if the session is closed (e.g., lock lost, unloaded).
	.unloadPromise Promise? -- Promise tracking an ongoing unload operation.

	.keyInfo DataStoreKeyInfo? -- DataStoreKeyInfo obtained during the initial load.

	.logger Log.Logger -- Logger instance specific to this session (includes key).
]=]
type SessionProps<T> = {
	_cleanupAutosave: (() -> ())?,
	key: string,
	ctx: Types.StoreContext<T>,
	lockHandle: Locks.LockHandle,
	userIds: { number }?,
	data: T?,
	appliedMigrations: { string },
	changeSet: { [string]: true },
	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	queue: PromiseQueue.PromiseQueue,
	txLockPromise: Promise.Promise?,
	closed: boolean,
	unloadPromise: Promise.Promise?,
	keyInfo: DataStoreKeyInfo?,
	logger: Log.Logger,
}

--[=[
	Represents an active, locked session for a specific data key.

	@type Session<T> typeof(setmetatable({} :: SessionProps<T>, {} :: SessionImpl<T>))
	@within Session
]=]
export type Session<T> = typeof(setmetatable({} :: SessionProps<T>, {} :: SessionImpl<T>))

--[=[
	Parameters for the static Session.load method.

	@interface LoadSessionParams<T>
	@within Session
	@private
	.key string
	.storeContext Types.StoreContext<T>
	.userIds { number }?
]=]
type LoadSessionParams<T> = {
	key: string,
	storeContext: Types.StoreContext<T>,
	userIds: { number }?,
}
-- Runtime check for LoadSessionParams.
local loadSessionParamsCheck = t.strictInterface({
	key = t.string,
	storeContext = t.any, -- StoreContext is a complex type, using `any` for simplicity
	userIds = t.optional(t.array(t.number)),
})

--[=[
	Parameters for the internal load helper function.

	@interface LoadParams
	@within Session
	@private
	.storeContext Types.StoreContext<any>
	.key string
]=]
export type LoadParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
}

--[=[
	Result structure for the internal load helper function.

	@interface LoadResult
	@within Session
	@private
	.data any
	.appliedMigrations { string }
	.orphanedFiles { Types.File }
	.currentFile Types.File?
	.keyInfo DataStoreKeyInfo?
]=]
export type LoadResult = {
	data: any,
	appliedMigrations: { string },
	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	keyInfo: DataStoreKeyInfo?,
}

--[=[
	Internal helper function to perform the multi-stage loading process for a key.
	This runs *after* the lock has been acquired.

	Steps:
	1. Get the main record from `recordStore`.
	2. Extract metadata (applied migrations, orphaned files).
	3. If a file reference exists, read the file data (potentially from shards via `Files.read`).
	4. If file data contains transaction info (`txInfo`), resolve the transaction state via `Transactions.readTx`.
	5. If no data found yet, attempt to import legacy data via `ctx.importLegacyData`.
	6. If still no data, use the `ctx.template` as the base.
	7. Apply any pending migrations via `Migrations.apply`.
	8. Return the final loaded data and metadata.

	@within Session
	@private
	@param params LoadParams -- Parameters for loading.
	@return Promise<LoadResult> -- Promise resolving with the loaded data and metadata.
]=]
local function load(params: LoadParams): Promise.TPromise<LoadResult>
	local ctx = params.storeContext
	local key = params.key

	local logger = ctx.logger:extend({ method = "load", key = params.key })
	logger:log("trace", `loading key`)

	-- Initialize default metadata
	local appliedMigrations: { string } = Migrations.getStepNames(ctx.migrationSteps)
	local orphanedFiles: { Types.File } = {}
	local currentFile: Types.File?
	local keyInfo: DataStoreKeyInfo?

	-- 1. Get the main record
	return dataStoreRetry(function()
			return ctx.recordStore:GetAsync(key)
		end)
		:andThen(function(record: Types.DataStoreRecord?, _keyInfo: DataStoreKeyInfo?)
			-- 2. Extract metadata
			logger:log("trace", "got record")
			if record == nil then
				record = {} :: Types.DataStoreRecord -- Handle case where key doesn't exist yet
			end
			assert(record, "luau") -- Forcefully narrowing type due to old type solver limitations

			keyInfo = _keyInfo
			if record.appliedMigrations then
				appliedMigrations = record.appliedMigrations
			end

			if record.orphanedFiles then
				orphanedFiles = record.orphanedFiles
			end

			-- 3. Read file data if reference exists
			local file = record.file
			if file then
				if Files.isLargeFile(file) then
					currentFile = file -- Store reference if it's sharded
				end

				logger:log("trace", "reading file", { file = HttpService:JSONEncode(file) })
				local readParams: Files.ReadParams = {
					store = ctx.shardStore,
					file = file,
				}
				return Files.read(readParams)
			end

			logger:log("trace", "no file reference in record")
			return nil :: any -- No file means no TxInfo
		end)
		:andThen(function(txInfo: Types.TxInfo?): Promise.TPromise<any?>
			-- 4. Resolve transaction state if TxInfo exists
			if txInfo then
				logger:log("trace", "got txInfo, resolving transaction", { txInfo = txInfo })

				local readTxParams = {
					store = ctx.txStore,
					txInfo = txInfo,
				}
				return Transactions.readTx(readTxParams)
			end

			logger:log("trace", "no txInfo from file")
			return Promise.resolve(nil) -- No TxInfo means no data from file
		end)
		:andThen(function(data: any?)
			-- 5. Attempt legacy import if no data yet
			if data ~= nil then
				logger:log("trace", "got data from file/transaction")
				return data -- Data found, proceed to migrations
			end

			local importLegacyData = ctx.importLegacyData
			if importLegacyData == nil then
				logger:log("trace", "no data, no importLegacyData function provided")
				return nil -- No data, no import function, proceed to template
			end

			-- Try importing
			logger:log("trace", "no data, attempting to import legacy data")
			local importOk, importResult = pcall(importLegacyData, key)
			if not importOk then
				logger:log("error", "failed to import legacy data", { error = importResult })
				return Promise.reject(`Failed to import legacy data for key {key}: {importResult}`)
			end

			local oldData = importResult
			if oldData == nil then
				logger:log("trace", "legacy import returned nil")
				return nil -- Import returned nothing, proceed to template
			else
				-- Data was imported, assume no migrations have been applied to it
				appliedMigrations = {}
				logger:log("trace", "imported legacy data", { oldData = oldData })
				return oldData -- Imported data found, proceed to migrations
			end
		end)
		:andThen(function(data: any?)
			-- 6. Use template if still no data
			if data == nil then
				logger:log("trace", "no data found, using template")
				data = Tables.copyDeep(ctx.template)
			end
			assert(data, "luau") -- Forcefully narrowing type due to old type solver limitations

			-- 7. Apply migrations
			if #ctx.migrationSteps > 0 then
				logger:log("debug", "applying migrations if necessary")
				local migrationParams: Migrations.ApplyParams = {
					logger = logger:extend({ component = "Migrations" }),
					data = data,
					steps = ctx.migrationSteps,
					appliedMigrations = appliedMigrations,
				}

				return Migrations.apply(migrationParams):andThen(function(result: Migrations.ApplyResult)
					-- Update appliedMigrations list based on migration result
					appliedMigrations = result.appliedMigrations
					logger:log(
						"trace",
						"migrations applied",
						{ data = result.data, appliedMigrations = appliedMigrations }
					)
					return result.data -- Return the potentially migrated data
				end)
			end

			-- No migrations to apply or needed
			logger:log("trace", "data loaded (no migrations run)")
			return data
		end)
		:andThen(function(finalData)
			-- 8. Return final result
			logger:log("trace", "load process complete")
			local loadResult: LoadResult = {
				data = finalData,
				appliedMigrations = appliedMigrations,
				orphanedFiles = orphanedFiles,
				currentFile = currentFile,
				keyInfo = keyInfo,
			}
			return loadResult
		end)
end

local Session: SessionImpl<any> = {} :: SessionImpl<any>
Session.__index = Session

--[=[
	Parameters for the internal createSession function.

	@interface CreateSessionParams
	@within Session
	@private
	.storeContext Types.StoreContext<any>
	.key string
	.lockHandle Locks.LockHandle
	.userIds { number }?
	.appliedMigrations { string }
	.orphanedFiles { Types.File }
	.currentFile Types.File?
	.keyInfo DataStoreKeyInfo?
]=]
type CreateSessionParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
	lockHandle: Locks.LockHandle,
	userIds: { number }?,
	appliedMigrations: { string },
	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	keyInfo: DataStoreKeyInfo?,
}

--[=[
	Internal factory function to create a new Session instance.
	Initializes the session state based on loaded data and acquired lock.

	@within Session
	@private
	@param params CreateSessionParams -- Parameters for session creation.
	@return Session<T> -- The newly created session instance.
]=]
local function createSession<T>(params: CreateSessionParams): Session<T>
	local logger = params.storeContext.logger:extend({ key = params.key })

	-- Create a dedicated queue for this session's save/unload/tx operations
	local queue = PromiseQueue.new({
		logger = logger:extend({ component = "PromiseQueue" }),
	})

	local props: SessionProps<T> = {
		key = params.key,
		ctx = params.storeContext,
		lockHandle = params.lockHandle,

		userIds = params.userIds,

		data = nil, -- Initial data set later by mutateKey
		appliedMigrations = params.appliedMigrations,

		changeSet = {}, -- Starts with no unsaved changes

		orphanedFiles = params.orphanedFiles,
		currentFile = params.currentFile,

		queue = queue,
		txLockPromise = nil, -- Not initially locked by a transaction

		closed = false, -- Starts open
		unloadPromise = nil, -- Not initially unloading

		keyInfo = params.keyInfo,
		logger = logger,
		_cleanupAutosave = nil, -- Autosave not started yet
	}

	return setmetatable(props, Session) :: Session<T>
end

--[=[
	Static method to load data and create a Session. This is the main entry point
	called by `Store:load`.

	Steps:
	1. Acquire the distributed lock for the key using `Locks.acquireLock`.
	2. If lock acquired, call the internal `load` helper function.
	3. If load successful and lock still held, create the Session instance using `createSession`.
	4. Set up lock loss handling (`lockHandle.onLockLost`) to close the session.
	5. Initiate background cleanup for any orphaned files found during load.
	6. Set the initial data in the session using `mutateKey`.
	7. Return the created Session.
	8. Ensure the lock is released if loading fails at any stage.

	@within Session
	@param params LoadSessionParams<T> -- Parameters for loading the session.
	@return Promise<Session<T>> -- Resolves with the new Session instance.
	@error "Lock was lost while loading key"
	@error string -- Propagates errors from `Locks.acquireLock` or internal `load`.
]=]
function Session.load<T>(params: LoadSessionParams<T>): Promise.TPromise<Session<T>>
	assert(loadSessionParamsCheck(params))

	local ctx = params.storeContext
	local logger = ctx.logger:extend({ method = "load", key = params.key })

	-- 1. Acquire lock
	local acquireLockParams: Locks.AcquireLockParams = {
		storeContext = ctx,
		key = params.key,
		duration = Constants.LOCK_DURATION_SECONDS,
		refreshInterval = Constants.LOCK_REFRESH_INTERVAL_SECONDS,
	}

	return Locks.acquireLock(acquireLockParams):andThen(function(lockHandle)
		-- Lock acquired, proceed to load data
		local loadParams: LoadParams = {
			storeContext = ctx,
			key = params.key,
		}

		-- 2. Call internal load helper
		return load(loadParams):andThen(function(loadResult: LoadResult)
			-- 3. Check lock still held after potentially long load operation
			if not lockHandle.isLocked() then
				logger:log("error", "lock was lost while loading key")
				-- Lock release handled by the `finally` block below
				return Promise.reject("Lock was lost while loading key")
			end

			-- 4. Create Session instance
			local createParams: CreateSessionParams = {
				storeContext = ctx,
				key = params.key,
				lockHandle = lockHandle,
				userIds = params.userIds,
				appliedMigrations = loadResult.appliedMigrations,
				orphanedFiles = loadResult.orphanedFiles,
				currentFile = loadResult.currentFile,
				keyInfo = loadResult.keyInfo,
			}
			local session = createSession(createParams)

			-- 5. Set up lock loss handler
			lockHandle.onLockLost(function()
				logger:log("warn", "lock was lost, closing session and stopping autosave")
				session.closed = true
				session:stopAutosaving()
				-- Mark unload as immediately resolved if lock is lost
				session.unloadPromise = Promise.resolve()
				-- Trigger Store's onLockLost callback if provided
				if ctx.onLockLost then
					ctx.onLockLost(params.key)
				end
			end)

			-- 6. Initiate orphan cleanup for files found during load
			for _, file in loadResult.orphanedFiles do
				session:orphanFile(file)
			end

			-- 7. Set initial data (triggers changed callbacks if enabled)
			logger:log("trace", "loaded key, setting initial data", { data = loadResult.data })
			session:mutateKey(loadResult.data)

			-- 8. Return the fully initialized session
			return session :: any
		end):finally(function(status): ()
			-- 9. Ensure lock release on failure
			-- This runs if `load(loadParams)` or the subsequent steps reject, or if the load was canceled.
			if status ~= Promise.Status.Resolved then
				logger:log("trace", "failed to load key, releasing lock")
				-- Attempt to release the lock, but don't block or fail further if release fails.
				lockHandle.release():catch(function(e)
					logger:log("warn", "failed to release lock after load failure", { error = e })
				end)
			end
		end)
	end)
end

--[=[
	Internal method to trigger a save operation if there are pending changes.
	This is called by `Session:save` and `Session:unload`.

	@within Session
	@private
	@return Promise -- Resolves when the save is complete (or immediately if no changes).
]=]
function Session:updateRecord(): Promise.TPromise<any>
	local logger = self.logger:extend({ method = "updateRecord" })
	logger:log("trace", "updateRecord called")

	-- Check if there are any unsaved changes
	if self:isSaved() then
		logger:log("trace", "no changes detected, skipping write")
		return Promise.resolve() -- Nothing to save
	end

	-- Prepare the data structure to be saved. TxInfo is the harness even if there's no transaction.
	local txInfo: Types.TxInfo = { committedData = self.data }

	logger:log("trace", "writing record via writeRecord", { txInfo = txInfo })
	-- Delegate the actual writing process to writeRecord
	return self:writeRecord(txInfo)
end

--[=[
	Marks a file (usually an older, sharded file) for deletion and starts a
	background task to remove its shards from the `shardStore`.

	Handles DataStore budget limitations by waiting if the budget is too low.

	@within Session
	@private
	@param file Types.File -- The file metadata (must include `shard` and `count` if sharded).
]=]
function Session:orphanFile(file: Types.File): ()
	-- Only sharded files need cleanup
	if not Files.isLargeFile(file) then
		return
	end
	local logger = self.ctx.logger:extend({ method = "orphanFile", key = self.key, shard = file.shard })

	logger:log("trace", "adding file to orphaned list", { file = file })
	-- Add to list immediately so `writeRecord` includes it if it runs concurrently.
	table.insert(self.orphanedFiles, file)

	-- Start background cleanup task
	task.spawn(function()
		-- Wait for sufficient DataStore budget before proceeding
		-- RemoveAsync uses the SetIncrementAsync budget.
		while true do
			local minBudget = 100 -- Arbitrary minimum budget threshold
			local curBudget =
				self.ctx.dataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementAsync)
			if curBudget < minBudget then
				logger:log("debug", "insufficient budget for orphan cleanup, waiting", {
					curBudget = curBudget,
					minBudget = minBudget,
				})
				task.wait(1) -- Wait and retry
			else
				break -- Budget sufficient
			end
		end

		logger:log("debug", "sufficient budget, processing orphaned file")

		-- Create promises to remove each shard
		local promises = {}
		for i = 1, file.count do
			logger:log("trace", `Queueing removal of shard {i} of {file.count}`)
			table.insert(
				promises,
				dataStoreRetry(function()
					-- Construct shard key and remove it
					return self.ctx.shardStore:RemoveAsync(`{file.shard}-{i}`)
				end)
			)
		end

		-- Wait for all shard removals to complete
		Promise.all(promises)
			:andThen(function()
				logger:log("trace", "successfully removed all shards for orphaned file")
				-- Remove the file from the session's orphaned list now that it's cleaned up.
				for i, otherFile in self.orphanedFiles do
					if Tables.equalsDeep(file, otherFile) then
						table.remove(self.orphanedFiles, i)
						break
					end
				end
			end)
			:catch(function(err)
				-- Log error but don't retry indefinitely. The file remains in orphanedFiles.
				-- Subsequent removals on already removed keys are idempotent.
				logger:log("error", `failed to remove shards for orphaned file: {err}`)
			end)
			:finally(function()
				logger:log("trace", "finished processing orphaned file task")
			end)
	end)
end

--[=[
	Core internal method responsible for writing the current session data to DataStores.

	Steps:
	1. Write the data (as `txInfo`) to potentially multiple shards using `Files.write`.
	2. If sharding fails, mark the failed shards as orphaned and reject.
	3. If file write succeeds, check if the session lock is still held.
	4. If lock lost, mark the newly written file as orphaned and reject.
	5. Prepare the main record (`DataStoreRecord`) containing metadata (migrations,
	   new file reference, list of files now orphaned by this save).
	6. Write the main record to the `recordStore` using SetAsync.
	7. If record write succeeds:
		a. Mark the *previous* `currentFile` (if any) as orphaned using `orphanFile`.
		b. Update `self.currentFile` to the newly written file reference.
		c. Return the written record.
	8. If record write fails, mark the newly written file as orphaned and reject.

	@within Session
	@private
	@param txInfo Types.TxInfo -- The data payload to write (contains `committedData`).
	@return Promise<Types.DataStoreRecord> -- Resolves with the written record on success.
	@error "lock was lost while writing file"
	@error string -- Propagates errors from `Files.write` or `SetAsync`.
]=]
function Session:writeRecord(txInfo: Types.TxInfo): Promise.TPromise<Types.DataStoreRecord>
	local logger = self.logger:extend({ method = "writeRecord" })
	logger:log("trace", "writeRecord called")

	-- 1. Write data to file (potentially sharded)
	local writeParams: Files.WriteParams = {
		store = self.ctx.shardStore,
		data = txInfo,
		maxShardSize = Constants.MAX_CHUNK_SIZE,
		key = self.key,
		userIds = self.userIds,
	}
	logger:log("trace", "calling Files.write", { writeParams = writeParams })

	return Files.write(writeParams)
		:catch(function(err: Files.WriteError)
			-- 2. Handle file write failure
			logger:log("error", "Files.write failed", { error = err.error })
			-- Mark the potentially partially written shards for cleanup
			self:orphanFile(err.file)
			return Promise.reject(err.error)
		end)
		:andThen(function(file: Types.File)
			-- File write successful
			logger:log("trace", "Files.write succeeded", { file = file })

			-- 3. Check lock status *after* potentially long file write
			if not self.lockHandle.isLocked() then
				logger:log("error", "lock was lost while writing file")
				-- Mark the newly created file/shards for cleanup as they are now unreachable
				self:orphanFile(file)
				return Promise.reject("lock was lost while writing file")
			end

			-- 5. Prepare the main record
			-- Clone orphanedFiles list at this point to avoid race conditions with background cleanup.
			local stagedOrphanedFiles = table.clone(self.orphanedFiles)
			-- Add the file that *this* save is replacing to the list of orphans for this record.
			if self.currentFile then
				table.insert(stagedOrphanedFiles, self.currentFile)
			end

			local record: Types.DataStoreRecord = {
				appliedMigrations = self.appliedMigrations,
				file = file, -- Reference to the file structure just written
				orphanedFiles = stagedOrphanedFiles,
			}

			-- 6. Write the main record
			logger:log("trace", "writing main record", { record = record })
			return dataStoreRetry(function()
					return self.ctx.recordStore:SetAsync(self.key, record, self.userIds)
				end)
				:andThen(function()
					-- 7. Record write successful
					logger:log("trace", "main record written successfully")

					-- a. Orphan the previous file now that the record points to the new one
					if self.currentFile then
						self:orphanFile(self.currentFile)
					end
					-- b. Update session state to point to the new file
					self.currentFile = if Files.isLargeFile(file) then file else nil

					-- c. Return the record written
					return record
				end)
				:catch(function(err)
					-- 8. Handle record write failure
					logger:log("error", "failed to write main record", { error = err })
					-- Mark the file/shards created in step 1 for cleanup as the record update failed.
					self:orphanFile(file)
					return Promise.reject(err)
				end)
		end)
end

--[=[
	Checks if the session has any unsaved changes.

	@within Session
	@return boolean -- True if there are no unsaved changes, false otherwise.
]=]
function Session:isSaved(): boolean
	-- The changeSet is empty if and only if `next` returns nil.
	return next(self.changeSet) == nil
end

--[=[
	Internal method to update the session's in-memory data state.
	Marks the session as having unsaved changes and updates the data.

	@within Session
	@private
	@param data any -- The new data value.
]=]
function Session:setData(data: any): ()
	-- Generate a unique ID for this mutation and add it to the changeSet.
	local mutationId = HttpService:GenerateGUID(false)
	self.changeSet[mutationId] = true
	-- Freeze and update the data reference.
	Tables.freezeDeep(data)
	self.data = data
end

--[=[
	Internal method called after data has been changed (either initially loaded or via `update`).
	Updates the session state (`setData`) and triggers any configured `changedCallbacks`.

	@within Session
	@private
	@param newData any -- The new data value.
]=]
function Session:mutateKey(newData: any): ()
	local oldData = self.data -- Store reference to previous data

	-- Update internal data (sets .data and marks changeSet)
	self:setData(newData)

	-- Trigger change callbacks asynchronously
	for _, callback in self.ctx.changedCallbacks do
		task.spawn(callback, self.key, self.data, oldData)
	end
end

--[=[
	Starts the background autosave loop for this session.
	Does nothing if already started or if the session is closed.

	@within Session
]=]
function Session:startAutosaving(): ()
	local logger = self.logger:extend({ method = "startAutosaving" })

	if self._cleanupAutosave then
		logger:log("warn", "autosave already started")
		return
	end
	if self.closed then
		logger:log("warn", "Session is closed, not starting autosave")
		return
	end

	logger:log("trace", "starting autosave loop")
	local stop = false -- Flag to signal loop termination

	-- Spawn the loop in a separate thread
	task.spawn(function()
		while true do
			-- Wait for the configured interval
			-- This is at the top of the loop to ensure the first wait is immediate - we just loaded the session.
			task.wait(Constants.AUTOSAVE_INTERVAL_SECONDS)
			-- Check if stopped or closed during wait
			if self.closed or stop then
				logger:log("trace", "autosave loop stopping", { closed = self.closed, stop = stop })
				break
			end

			-- Attempt to save any pending changes
			logger:log("trace", "autosave triggered")
			local ok, err = self:save():await()
			if not ok then
				-- Log error but continue the loop
				logger:log("warn", "failed to autosave key", { error = err })
			else
				logger:log("trace", "autosave completed successfully")
			end
		end
	end)

	-- Store the cleanup function to stop the loop
	self._cleanupAutosave = function()
		logger:log("trace", "cleanup function called, signaling autosave loop to stop")
		stop = true
		self._cleanupAutosave = nil -- Prevent multiple calls
	end
end

--[=[
	Stops the background autosave loop if it's running.

	@within Session
]=]
function Session:stopAutosaving(): ()
	if self._cleanupAutosave then
		self.logger:log("trace", "stopping autosave loop")
		self._cleanupAutosave()
	else
		self.logger:log("trace", "autosave loop not running or already stopped")
	end
end

--[=[
	Initiates the graceful shutdown process for the session.
	Stops autosaving, queues a final save operation, and releases the lock.

	@within Session
	@return Promise -- Resolves when the unload process is complete.
]=]
function Session:unload(): Promise.Promise
	local logger = self.logger:extend({ method = "unload" })
	logger:log("trace", "unload called")

	-- If unload is already in progress, return the existing promise
	if self.unloadPromise then
		logger:log("trace", "unload already in progress, returning existing promise")
		return self.unloadPromise
	end

	-- Mark session as closed immediately
	self.closed = true
	-- Stop the autosave loop
	self:stopAutosaving()

	logger:log("trace", "queueing final save and lock release")
	-- Add the final operations to the session's queue to ensure serialization
	self.unloadPromise = self
		.queue
		:add(function()
			-- Perform a final save attempt if there are changes
			logger:log("trace", "performing final updateRecord before unloading")
			return self:updateRecord()
		end)
		:andThenReturn(nil) -- Discard result of updateRecord
		:finally(function()
			-- This block runs regardless of whether the final save succeeded or failed
			logger:log("trace", "releasing lock as part of unload")
			-- Attempt to release the lock, logging any errors but not failing unload
			return self.lockHandle.release():catch(function(e)
				logger:log("warn", "failed to release lock during unload", { error = e })
			end)
		end)

	return self.unloadPromise :: any
end

--[=[
	Gets the current data for the session. Value returned is deep frozen to prevent modification.

	@within Session
	@return Promise<T> -- Resolves immediately with the data.
]=]
function Session:get<T>(): Promise.TPromise<T>
	return Promise.resolve(self.data) :: any
end

-- Internal function to encapsulate shared logic for update and updateImmutable.
local function updateInternal(
	self: Session<any>,
	transformFunction: (data: any) -> any | false,
	immutable: boolean,
	logger: Log.Logger
): Promise.TPromise<boolean>
	-- Use Promise.new to handle potential waits for txLockPromise
	return Promise.new(function(resolve, reject)
		-- Wait if a multi-key transaction is currently holding the lock on this session
		while self.txLockPromise ~= nil do
			logger:log("trace", "waiting for txLockPromise to resolve")
			self.txLockPromise:await()
			-- Re-check if closed after waiting, as lock loss could occur during tx
			if self.closed then
				logger:log("warn", "Session closed while waiting for txLockPromise, rejecting update")
				return reject("Session is closed")
			end
		end
		logger:log("trace", `txLockPromise resolved or was nil, proceeding with update`)

		-- Store a reference to our current data - we'll need this later to
		-- check if the data changed at all
		local currentData = self.data

		local nextData
		if immutable then
			-- If immutable is true, we'll pass in `self.data` (which is frozen)
			-- and expect to get a copy-on-write result from `transformFunction`
			nextData = self.data
		else
			-- If immutable is false, we allow the transform to modify the data
			-- directly, so we need a deep copy in case we want to abandon the
			-- changes
			nextData = Tables.copyDeep(self.data)
		end

		-- Execute the transform function safely using `noYield`
		local transformOk, result = pcall(noYield, transformFunction, nextData :: any)
		if not transformOk then
			logger:log("error", "transformFunction errored", { error = result })
			return reject(`transformFunction failed: {result}`)
		end

		-- Check the return value of the transform function
		if immutable == false then
			-- If immutable is false, we expect the transform to return a boolean
			if typeof(result) ~= "boolean" then
				logger:log("error", "transformFunction did not return a boolean")
				return reject("transformFunction must return a boolean")
			end
		else
			-- If immutable is true, we expect the transform to return a new copy of data or false
			if typeof(result) ~= "table" and result ~= false then
				logger:log("error", "transformFunction returned a boolean when it should return data or false")
				return reject("transformFunction must return data or false")
			end
		end

		-- If transform returned false, abort the update
		if result == false then
			logger:log("trace", "transformFunction returned false, update aborted")
			return resolve(false)
		end

		if immutable then
			-- If immutable is true, we expect the transform to return a new
			-- copy of data
			nextData = result :: any
		end

		-- Validate the modified data against the schema
		local schemaOk, err = self.ctx.schema(nextData :: any)
		if not schemaOk then
			logger:log("error", "schema validation failed after transform", { error = err })
			return reject(`Store:update schema validation failed: {err}`)
		end

		-- Check if the data actually changed
		if Tables.equalsDeep(nextData :: any, currentData :: any) then
			logger:log("trace", "transform resulted in no data change, resolving true")
			return resolve(true) -- Considered successful, but data remains same
		end

		-- TODO: If immutable is false, we should comb through the data and
		-- reconstruct a proper copy-on-write structure to make change detecting
		-- easier in `changedCallbacks`

		-- Data changed and is valid, apply the mutation
		self:mutateKey(nextData)

		logger:log("trace", "update applied successfully")

		-- Resolve indicating changes were committed
		return resolve(true)
	end)
end

--[=[
	Applies updates to the session's data via a transform function.
	Ensures the transform runs without yielding and validates the result against the schema.
	Allows you to directly mutate the data in-place.

	@within Session
	@param transformFunction (data: T) -> boolean -- Function to modify data. Must return `true` to commit, `false` to abort.
	@return Promise<boolean> -- Resolves with `true` if changes were committed, `false` if aborted by the transform.
	@error "Session is closed"
	@error "transformFunction failed: ..." -- If the transform function errors.
	@error "transformFunction must return a boolean"
	@error "Store:update schema validation failed: ..." -- If the modified data fails schema validation.
]=]
function Session:update<T>(transformFunction: (data: T) -> boolean): Promise.TPromise<boolean>
	assert(t.callback(transformFunction))

	local logger = self.logger:extend({ method = "update" })
	logger:log("trace", "update called")

	-- Reject if session is closed
	if self.closed then
		logger:log("warn", "Session is closed, rejecting update")
		return Promise.reject("Session is closed")
	end

	return updateInternal(self, transformFunction, false, logger)
end

--[=[
	Applies updates to the session's data via a transform function.
	Ensures the transform runs without yielding and validates the result against the schema.
	Requires the use of copy-on-write semantics in transformFunction, where
	the data is not directly mutated but instead a new copy is returned.

	@within Session
	@param transformFunction (data: T) -> T | false -- Function to modify data. Must return a new copy of the data with changes to commit changes, or `false` to abort.
	@return Promise<boolean> -- Resolves with `true` if changes were committed, `false` if aborted by the transform.
	@error "Session is closed"
	@error "transformFunction failed: ..." -- If the transform function errors.
	@error "transformFunction must return a boolean"
	@error "Store:update schema validation failed: ..." -- If the modified data fails schema validation.
]=]
function Session:updateImmutable<T>(transformFunction: (data: T) -> T | false): Promise.TPromise<boolean>
	assert(t.callback(transformFunction))

	local logger = self.logger:extend({ method = "updateImmutable" })
	logger:log("trace", "updateImmutable called")

	-- Reject if session is closed
	if self.closed then
		logger:log("warn", "Session is closed, rejecting update")
		return Promise.reject("Session is closed")
	end

	return updateInternal(self, transformFunction, true, logger)
end

--[=[
	Queues a save operation for the current session state if changes are pending.
	Uses the session's PromiseQueue to serialize saves.

	@within Session
	@return Promise -- Resolves when the save operation completes (or immediately if no changes).
	@error "Session is closed"
]=]
function Session:save(): Promise.Promise
	local logger = self.logger:extend({ method = "save" })
	logger:log("trace", "save called")

	-- Reject if session is closed
	if self.closed then
		logger:log("warn", "Session is closed, rejecting save")
		return Promise.reject("Session is closed")
	end
	-- If no changes, resolve immediately
	if self:isSaved() then
		logger:log("trace", "no changes pending, resolving save immediately")
		return Promise.resolve()
	end

	-- Capture the current changeSet IDs at the time save was called
	local changesToSave = table.clone(self.changeSet)

	logger:log("trace", "queueing save operation")
	-- Add the save logic to the session's queue
	return self.queue:add(function()
		logger:log("trace", "save task running from queue")

		-- Check if the changes captured earlier (`changesToSave`) have already
		-- been saved by a *different* save task that ran before this one.
		local changesWereAlreadySaved = true
		for id in self.changeSet do -- Check the *current* changeSet
			if changesToSave[id] then -- Is an ID from *our* captured set still present?
				changesWereAlreadySaved = false -- At least one change is still pending, we need to save
				break
			end
		end

		if changesWereAlreadySaved then
			logger:log("trace", "changes were already saved by another task, skipping redundant save")
			return Promise.resolve() -- No need to save again
		end

		-- Capture the *current* changeSet again, as more changes might have occurred
		-- while this task was waiting in the queue.
		local currentChanges = table.clone(self.changeSet)

		logger:log("trace", "saving current changes", { changes = currentChanges })
		-- Perform the actual save via updateRecord
		return self:updateRecord():andThen(function()
			-- Save successful, remove the saved change IDs from the session's changeSet
			for id in currentChanges do
				self.changeSet[id] = nil
			end
			logger:log("trace", "changes saved successfully, updated changeSet", { latestChangeSet = self.changeSet })
		end)
		-- Errors from updateRecord will propagate through the queue's promise
	end)
end

return Session
