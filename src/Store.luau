--!strict

--[=[
	A Store coordinates Sessions and provides a safe way to interact with persistent data.

	```lua
	local store = Store.createStore({
		name = "PlayerData",
		template = {
			coins = 0,
			items = {},
		},
		schema = function(data)
			return typeof(data.coins) == "number" and typeof(data.items) == "table", 
			"Invalid data format"
		end,
	})

	-- Load data for a player
	store:load("player_1"):andThen(function()
		-- Get current data
		return store:get("player_1")
	end):andThen(function(data)
		print(data.coins) -- 0
		
		-- Update data
		return store:update("player_1", function(data)
			data.coins += 100
			return true -- Must return true to commit changes
		end)
	end)
	```

	@class Store
]=]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Constants)
local Files = require(script.Parent.Files)
local JsonPatch = require(script.Parent.JsonPatch)
local Locks = require(script.Parent.Locks)
local Session = require(script.Parent.Session)
local Log = require(script.Parent.Log)
local MockDataStoreService = require(script.Parent.MockDataStoreService)
local MockMemoryStoreService = require(script.Parent.MockMemoryStoreService)
local PromiseQueue = require(script.Parent.PromiseQueue)
local Transactions = require(script.Parent.Transactions)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)
local t = require(script.Parent.Parent:WaitForChild("t").lib.ts).t
local Types = require(script.Parent.Types)
local dataStoreRetry = require(script.Parent.dataStoreRetry)
local noYield = require(script.Parent.noYield)

--[=[
	Configuration for creating a new Store.

	@interface StoreConfig
	.name string -- Name of the store
	.template T -- Template/default value for new data
	.schema (value: any) -> (boolean, string?) -- Validates data format
	.migrationSteps? { MigrationStep } -- Steps to migrate old data formats
	.importLegacyData? (key: string) -> any? -- Function to import legacy data
	.dataStoreService? DataStoreService -- Custom DataStore implementation
	.useMock? boolean -- Use mock DataStore (Studio only)
	.changedCallbacks? { (key: string, newData: T, oldData: T?) -> () } -- Run when data changes
	.logCallback? (logMessage: LogMessage) -> () -- Custom logging function
	.onLockLost? (key: string) -> () -- Called if DataStore lock is lost

	Example usage:
	```lua
	local config: StoreConfig<PlayerData> = {
		name = "PlayerData",
		template = {
			coins = 0,
			items = {},
		},
		schema = function(value)
			return typeof(value.coins) == "number", "coins must be a number"
		end,
	}
	```

	@within Store
]=]
export type StoreConfig<T> = {
	name: string,
	template: T,
	schema: (value: any) -> (boolean, string?),
	migrationSteps: { Types.MigrationStep }?,
	importLegacyData: ((key: string) -> any?)?,
	dataStoreService: DataStoreService?,
	memoryStoreService: MemoryStoreService?,
	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () }?,
	logCallback: ((logMessage: Types.LogMessage) -> ())?,
	onLockLost: ((key: string) -> ())?,
	useMock: boolean?,
	disableReferenceProtection: boolean?,
}
local storeConfigCheck = t.strictInterface({
	name = t.string,
	template = t.any,
	schema = t.callback,
	migrationSteps = t.optional(t.array(t.strictInterface({
		name = t.string,
		apply = t.callback,
	}))),
	importLegacyData = t.optional(t.callback),
	dataStoreService = t.optional(t.any),
	memoryStoreService = t.optional(t.any),
	changedCallbacks = t.optional(t.array(t.callback)),
	logCallback = t.optional(t.callback),
	onLockLost = t.optional(t.callback),
	useMock = t.optional(t.boolean),
	disableReferenceProtection = t.optional(t.boolean),
})

type ListVersionParams = {
	key: string,
	sortDirection: Enum.SortDirection?,
	minDate: number?,
	maxDate: number?,
	pageSize: number?,
}

type StoreImpl<T> = {
	__index: StoreImpl<T>,

	_withSession: (self: Store<T>, key: string, callback: (session: Session.Session<any>) -> ()) -> Promise.Promise,
	_getKeyInfo: (self: Store<T>, key: string) -> Promise.TPromise<DataStoreKeyInfo?>,

	load: (self: Store<T>, key: string, userIds: { number }?) -> Promise.Promise,
	unload: (self: Store<T>, key: string) -> Promise.Promise,
	get: (self: Store<T>, key: string) -> Promise.TPromise<T>,
	update: (self: Store<T>, key: string, transformFunction: (data: T) -> boolean) -> Promise.TPromise<boolean>,
	tx: (
		self: Store<T>,
		keys: { string },
		transformFunction: (state: { [string]: T }) -> boolean
	) -> Promise.Promise,
	save: (self: Store<T>, key: string) -> Promise.Promise,
	close: (self: Store<T>) -> Promise.Promise,

	peek: (self: Store<T>, key: string) -> Promise.TPromise<T>,
	probeLockActive: (self: Store<T>, key: string) -> Promise.TPromise<boolean>,
	listVersions: (self: Store<T>, params: ListVersionParams) -> Promise.TPromise<DataStoreVersionPages>,
	readVersion: (self: Store<T>, key: string, version: string) -> Promise.TPromise<T, DataStoreKeyInfo>,

	loadAsync: (self: Store<T>, key: string, userIds: { number }?) -> (),
	unloadAsync: (self: Store<T>, key: string) -> (),
	getAsync: (self: Store<T>, key: string) -> T,
	updateAsync: (self: Store<T>, key: string, transformFunction: (data: T) -> boolean) -> boolean,
	txAsync: (self: Store<T>, keys: { string }, transformFunction: (state: { [string]: T }) -> boolean) -> (),
	saveAsync: (self: Store<T>, key: string) -> (),
	closeAsync: (self: Store<T>) -> (),

	peekAsync: (self: Store<T>, key: string) -> T,
	probeLockActiveAsync: (self: Store<T>, key: string) -> boolean,
	listVersionsAsync: (self: Store<T>, params: ListVersionParams) -> DataStoreVersionPages,
	readVersionAsync: (self: Store<T>, key: string, version: string) -> (T, DataStoreKeyInfo),
}

type StoreProps<T> = {
	_ctx: Types.StoreContext<T>,
	_closed: boolean,
	_sessions: { [string]: Session.Session<T> },
	_lastTxId: string?,
	_loadPromises: { [string]: Promise.Promise },
	_unloadPromises: { [string]: Promise.Promise },
}

export type Store<T> = typeof(setmetatable({} :: StoreProps<T>, {} :: StoreImpl<T>))

local Store: StoreImpl<any> = {} :: StoreImpl<any>
Store.__index = Store

--[=[
	Creates a new Store with the given configuration.

	```lua
	local store = Store.createStore({
		name = "PlayerData",
		template = { coins = 0 },
		schema = function(data)
			return typeof(data.coins) == "number", "coins must be a number"
		end,
		
		-- Optional: Runs whenever data changes
		changedCallbacks = {
			function(key, newData, oldData)
				print(key, "changed from", oldData.coins, "to", newData.coins)
			end,
		},

		-- Optional: Called if lock is lost during session
		onLockLost = function(key)
			warn("Lost lock for", key)
		end,
	})
	```

	:::caution
	If schema validation fails at any point, operations will be rejected with the error message.
	:::

	@param config StoreConfig<T> -- Configuration for the store
	@return Store<T>
	@within Store
	@function createStore
]=]
local function createStore<T>(config: StoreConfig<T>): Store<T>
	assert(storeConfigCheck(config))

	local logger = Log.createLogger(config.logCallback or function() end, {
		lib = "lyra",
		store = config.name,
	})

	logger:log("debug", `creating store`)
	local dataStoreService = config.dataStoreService
	if dataStoreService == nil then
		if config.useMock then
			assert(RunService:IsStudio(), "useMock can only be true in Studio")
			logger:log("info", `using mock DataStoreService`)
			dataStoreService = (MockDataStoreService.new() :: any) :: DataStoreService
		else
			logger:log("trace", `using real DataStoreService`)
			dataStoreService = DataStoreService
		end
	end
	assert(dataStoreService, "luau")

	local memoryStoreService = config.memoryStoreService
	if memoryStoreService == nil then
		if config.useMock then
			assert(RunService:IsStudio(), "useMock can only be true in Studio")
			logger:log("info", `using mock MemoryStoreService`)
			memoryStoreService = (MockMemoryStoreService.new() :: any) :: MemoryStoreService
		else
			logger:log("trace", `using real MemoryStoreService`)
			memoryStoreService = MemoryStoreService
		end
	end
	assert(memoryStoreService, "luau")

	local migrationSteps = config.migrationSteps or {}

	local storeContext: Types.StoreContext<T> = {
		name = config.name,
		template = config.template,
		schema = config.schema,

		migrationSteps = migrationSteps,
		importLegacyData = config.importLegacyData,

		dataStoreService = dataStoreService,
		memoryStoreService = memoryStoreService,

		changedCallbacks = config.changedCallbacks or {},
		logger = logger,
		onLockLost = config.onLockLost,

		recordStore = dataStoreService:GetDataStore(`{Constants.RECORD_SCOPE}/{config.name}`),
		shardStore = dataStoreService:GetDataStore(`{Constants.SHARD_SCOPE}/{config.name}`),
		txStore = dataStoreService:GetDataStore(`{Constants.TX_SCOPE}/{config.name}`),
		lockHashMap = memoryStoreService:GetHashMap(`{Constants.LOCK_SCOPE}/{config.name}`),

		disableReferenceProtection = config.disableReferenceProtection or false,
	}

	local ok, err = storeContext.schema(storeContext.template)
	if not ok then
		error(`Failed to validate template: {err}`)
	end

	local self = setmetatable({
		_ctx = storeContext,
		_closed = false,
		_sessions = {},
		_lastTxId = nil,
		_loadPromises = {},
		_unloadPromises = {},
	}, Store)

	logger:log("trace", `created store`)
	return self
end

--[=[
	Loads data for the given key into memory and establishes a session.
	Must be called before using any other methods with this key.

	```lua
	store:load("player_1"):andThen(function()
		print("Data loaded!")
	end):catch(function(err)
		warn("Failed to load:", err)
	end)
	```

	@error "Load already in progress" -- Another load is already in progress for this key
	@error "Store is closed" -- The store has been closed
	@return Promise -- Resolves when data is loaded
	@within Store 
]=]
function Store:load(key: string, userIds: { number }?): Promise.Promise
	assert(t.string(key))
	assert(t.optional(t.array(t.number))(userIds))

	local logger = self._ctx.logger:extend({ method = "load", key = key })
	logger:log("trace", "attempting to load key")

	if self._closed then
		logger:log("warn", "attempted to load key while store is closed")
		return Promise.reject("Store is closed")
	end

	if self._sessions[key] and not self._unloadPromises[key] then
		logger:log("trace", "key is already loaded")
		return Promise.resolve()
	end

	if self._loadPromises[key] then
		logger:log("trace", "key is currently being loaded")
		return Promise.reject("Load already in progress")
	end

	local waitForUnload = Promise.try(function()
		local unloadPromise = self._unloadPromises[key]
		if unloadPromise then
			logger:log("trace", "waiting for unload to complete")
			unloadPromise:await()
		end
	end)

	local params = {
		storeContext = self._ctx,
		key = key,
		userIds = userIds,
	}
	local loadPromise = waitForUnload:andThenCall(Session.load, params):andThen(function(session)
		if self._closed then
			logger:log("warn", "store closed before key loaded")

			self._unloadPromises[key] = session:unload():finally(function()
				logger:log("trace", "key unloaded")
				self._unloadPromises[key] = nil
			end)

			return Promise.reject("Store closed before key loaded")
		end

		self._sessions[key] = session

		session:startAutosaving()
		session.lockHandle.onLockLost(function()
			if self._ctx.onLockLost then
				self._ctx.onLockLost(key)
			end
			self._sessions[key] = nil
		end)
	end)

	self._loadPromises[key] = loadPromise

	-- This chain does two things:
	-- 1. finally: If loadPromise is already settled, its finally block might
	--    run before the assignment above, leaving the promise in the table - so
	--    we run finally here to ensure it's removed.
	-- 2. catch: Some users might call load without handling rejections,
	--    triggering unhandled rejection warnings. Since Lyra logs the root
	--    error, we immediately mark the rejection as caught to silence the
	--    warning. This *doesn't* consume the rejection; it still propagates to
	--    the user.
	loadPromise
		:finally(function()
			self._loadPromises[key] = nil
		end)
		:catch(function() end)

	return loadPromise:finally(function(status)
		if status == (Promise :: any).Status.Cancelled then
			logger:log("trace", "load was cancelled")
			return Promise.reject("Load was cancelled")
		end
	end)
end

--[=[
	Syntactic sugar for `store:load(key):expect()`.
	
	See [Store:load]
]=]
function Store:loadAsync(key: string, userIds: { number }?): ()
	self:load(key, userIds):expect()
end

--[=[
	Unloads data for the given key from memory and ends the session.

	```lua
	store:unload("player_1"):andThen(function()
		print("Data unloaded!")
	end)
	```

	@error "Store is closed" -- The store has been closed
	@return Promise -- Resolves when data is unloaded
	@within Store
]=]
function Store:unload(key: string): Promise.Promise
	assert(t.string(key))

	local logger = self._ctx.logger:extend({ method = "unload", key = key })
	logger:log("trace", "attempting to unload key")

	if self._closed then
		logger:log("warn", "attempted to unload key while store is closed")
		return Promise.reject("Store is closed")
	end

	if self._loadPromises[key] then
		logger:log("trace", "key is being loaded, cancelling load")
		self._loadPromises[key]:cancel()
		return Promise.resolve()
	end

	if self._unloadPromises[key] then
		logger:log("trace", "key is being unloaded")
		return self._unloadPromises[key]
	end

	if not self._sessions[key] then
		logger:log("warn", "key not loaded")
		return Promise.resolve()
	end

	logger:log("trace", "unloading key")
	self._unloadPromises[key] = self._sessions[key]:unload():finally(function()
		logger:log("trace", "key unloaded")
		self._sessions[key] = nil
		self._unloadPromises[key] = nil
	end)

	return self._unloadPromises[key] or Promise.resolve()
end

--[=[
	Syntactic sugar for `store:unload(key):expect()`.
	
	See [Store:unload]
]=]
function Store:unloadAsync(key: string): ()
	self:unload(key):expect()
end

--[=[
	Internal helper to manage sessions.

	@within Store
	@return Promise -- Resolves with the result of the callback
	@private
]=]
function Store:_withSession(key: string, callback: (session: Session.Session<any>) -> any): Promise.Promise
	local logger = self._ctx.logger:extend({ method = "_withSession", key = key })

	return Promise.new(function(resolve, reject)
		if self._closed then
			logger:log("warn", "attempted to use key while store is closed")
			return reject("Store is closed")
		end

		local loadPromise = self._loadPromises[key]
		if loadPromise then
			logger:log("trace", "key being loaded, waiting")
			local loaded = loadPromise:await()
			if not loaded then
				return loadPromise:finally(function(status)
					if status == (Promise :: any).Status.Cancelled then
						logger:log("trace", "load cancelled")
						return reject("Load was cancelled")
					end
				end)
			end
		end

		if self._unloadPromises[key] then
			logger:log("warn", "key is being unloaded")
		end

		local session = self._sessions[key]
		if not session then
			logger:log("warn", "key not loaded")
			return reject("Key not loaded")
		end

		resolve(callback(session))
	end)
end

--[=[
	Returns the DataStoreKeyInfo associated with the given key, if available.

	@within Store
	@return Promise<DataStoreKeyInfo?> -- Resolves with the key info, or nil if not available
	@private
]=]
function Store:_getKeyInfo(key: string): Promise.TPromise<DataStoreKeyInfo?>
	return self:_withSession(key, function(session)
		return session.keyInfo
	end)
end

--[=[
	Gets the current data for the given key.

	```lua
	store:get("player_1"):andThen(function(data)
		print("Current coins:", data.coins)
	end):catch(function(err)
		warn("Failed to get data:", err)
	end)
	```

	@error "Key not loaded" -- The key hasn't been loaded with store:load()
	@error "Store is closed" -- The store has been closed
	@return Promise<T> -- Resolves with the current data
	@within Store
]=]
function Store:get<T>(key: string): Promise.TPromise<T>
	assert(t.string(key))

	return self:_withSession(key, function(session)
		return session:get()
	end)
end

--[=[
	Syntactic sugar for `store:get(key):expect()`.

	See [Store:get]
]=]
function Store:getAsync<T>(key: string): T
	return self:get(key):expect()
end

--[=[
	Updates data for the given key using a transform function.
	The transform function receives the current data and can modify it.
	Must return true to commit changes, or false to abort.

	```lua
	store:update("player_1", function(data)
		if data.coins < 100 then
			data.coins += 50
			return true -- Commit changes
		end
		return false -- Don't commit changes
	end):andThen(function()
		print("Update successful!")
	end):catch(function(err)
		warn("Update failed:", err)
	end)
	```

	@error "Key not loaded" -- The key hasn't been loaded with store:load()
	@error "Store is closed" -- The store has been closed
	@error "Schema validation failed" -- The transformed data failed schema validation
	@return Promise<boolean> -- Resolves when the update is complete, with a boolean indicating success
	@within Store
]=]
function Store:update<T>(key: string, transformFunction: (data: T) -> boolean): Promise.TPromise<boolean>
	assert(t.string(key))
	assert(t.callback(transformFunction))

	return self:_withSession(key, function(session)
		return session:update(transformFunction)
	end)
end

--[=[
	Syntactic sugar for `store:update(key, transformFunction):expect()`.

	See [Store:update]
]=]
function Store:updateAsync<T>(key: string, transformFunction: (data: T) -> boolean): boolean
	return self:update(key, transformFunction):expect()
end

--[=[
	Performs a transaction across multiple keys atomically.
	All keys must be loaded first. Either all changes are applied, or none are.

	```lua
	store:tx({"player_1", "player_2"}, function(state)
		-- Transfer coins between players
		if state.player_1.coins >= 100 then
			state.player_1.coins -= 100
			state.player_2.coins += 100
			return true -- Commit transaction
		end
		return false -- Abort transaction
	end):andThen(function()
		print("Transaction successful!")
	end):catch(function(err)
		warn("Transaction failed:", err)
	end)
	```

	@error "Key not loaded" -- One or more keys haven't been loaded
	@error "Store is closed" -- The store has been closed
	@error "Schema validation failed" -- The transformed data failed schema validation
	@error "Keys changed in transaction" -- The transform function modified the keys table
	@return Promise -- Resolves when the transaction is complete
	@within Store
]=]
function Store:tx<T>(keys: { string }, transformFunction: (state: { [string]: T }) -> boolean): Promise.Promise
	assert(t.array(t.string)(keys))
	assert(t.callback(transformFunction))

	local txId = HttpService:GenerateGUID(false)
	local logger = self._ctx.logger:extend({ method = "tx", keys = keys, txId = txId })

	logger:log("trace", "starting transaction")
	if self._closed then
		logger:log("warn", "attempted to start transaction while store is closed")
		return Promise.reject("Store is closed")
	end

	for _, key in keys do
		local session = self._sessions[key]
		if not session then
			return Promise.reject(`Key not loaded: {key}`)
		end
		if session.txLockPromise then
			return Promise.reject(`Key is already locked by another transaction: {key}`)
		end
		if session.closed then
			return Promise.reject(`Key is closed: {key}`)
		end
	end

	local txLockResolve
	local txLockPromise = Promise.new(function(resolve)
		txLockResolve = resolve
	end)

	local queues = Tables.map(keys, function(key)
		return self._sessions[key].queue
	end)

	-- Block Session:update calls during transaction execution by setting a lock
	-- promise on affected sessions. Promise resolves when transaction
	-- completes.
	local function withTxLock(fn: () -> Promise.Promise): Promise.Promise
		for _, key in keys do
			local session = self._sessions[key]
			session.txLockPromise = txLockPromise
		end
		logger:log("trace", "set txLockPromise on Sessions")

		return Promise.try(fn):finally(function()
			for _, key in keys do
				local session = self._sessions[key]
				if session.txLockPromise == txLockPromise then
					session.txLockPromise = nil :: any
				end
			end
			logger:log("trace", "cleared txLockPromise on Sessions")
			txLockResolve()
		end)
	end

	logger:log("trace", `acquiring PromiseQueue lock on keys`)
	return PromiseQueue.multiQueueAdd(queues, function()
		logger:log("trace", `acquired PromiseQueue lock on keys`)

		return withTxLock(function()
			local currentState = {}
			for _, key in keys do
				local session = self._sessions[key]
				currentState[key] = session.data
			end

			local nextState = Tables.copyDeep(currentState)
			local transformOk, result = pcall(noYield, transformFunction, nextState :: any)
			if not transformOk then
				logger:log("error", "tx transformFunction failed", { error = result })
				return Promise.reject(`Store:tx transformFunction failed: {result}`)
			end

			assert(typeof(result) == "boolean", "Transaction transform function must return a boolean")

			if result == false then
				logger:log("trace", "tx transformFunction returned false, skipping update")
				return Promise.reject("Transaction transform function returned false")
			end

			if self._ctx.disableReferenceProtection == false then
				-- We deep copy here to prevent references to internal state from
				-- being leaked. If we didn't, the transform function could modify
				-- the state after it runs, which shouldn't be allowed.
				nextState = Tables.copyDeep(nextState)
			end

			for _, key in keys do
				local schemaOk, err = self._ctx.schema(nextState[key] :: any)
				if not schemaOk then
					logger:log("error", `schema validation for key {key} failed: {err}`)
					return Promise.reject(`Store:tx schema validation failed: {err}`)
				end
			end

			local didKeysChange = false
			for key in currentState do
				if nextState[key] == nil then
					didKeysChange = true
					break
				end
			end
			for key in nextState do
				if currentState[key] == nil then
					didKeysChange = true
					break
				end
			end
			if didKeysChange then
				logger:log("error", "keys changed in transaction")
				return Promise.reject("Keys changed in transaction")
			end

			-- If no keys changed we can exit early, and if only one key
			-- changed, we can treat it as a normal :update.
			local changedKeys = {}
			for key in currentState do
				if not Tables.equalsDeep(currentState[key] :: any, nextState[key] :: any) then
					table.insert(changedKeys, key)
				end
			end

			if #changedKeys == 0 then
				logger:log("trace", "tx had no mutations, skipping update")
				return Promise.resolve()
			elseif #changedKeys == 1 then
				logger:log("trace", `tx only changed one key, treating as Session:update`)
				local key = changedKeys[1]
				self._sessions[key]:mutateKey(nextState[key])
				return Promise.resolve()
			end

			logger:log("trace", "tx changed multiple keys, beginning multi-key update")
			local patches = {}

			for key, newData in nextState do
				patches[key] = JsonPatch.createPatch(currentState[key], newData)
			end

			-- Represent 'failed' as `false` and 'committed' as `nil`. When
			-- committing, we can simply remove the status entry rather than
			-- updating all keys, saving writes for successful transactions.
			local prepareTxPromise = dataStoreRetry(function()
				return self._ctx.txStore:SetAsync(txId, false)
			end):catch(function(err)
				logger:log("error", "failed to prepare txId", { error = err })
				return Promise.reject("Failed to prepare tx")
			end)

			local keyWritePromises = prepareTxPromise:andThen(function()
				return Promise.all(Tables.map(keys, function(key)
					local txInfo = {
						txId = txId,
						txPatch = patches[key],
						committedData = currentState[key],
					}

					return self._sessions[key]:writeRecord(txInfo)
				end))
			end)

			local function revert(err)
				logger:log("error", "multi-key update or tx commit failed, reverting", { error = err })

				local cleanupPromises = Tables.map(keys, function(key)
					local txInfo = { committedData = currentState[key] }
					return self._sessions[key]:writeRecord(txInfo)
				end)

				return Promise.all(cleanupPromises)
					:andThen(function()
						logger:log("trace", "multi-key update reverted, cleaning up tx status")
						return dataStoreRetry(function()
							return self._ctx.txStore:RemoveAsync(txId)
						end)
					end)
					:andThen(function()
						logger:log("trace", "tx status cleaned up")
						return Promise.reject(err)
					end)
			end

			local updateAndCommitPromise = keyWritePromises
				:andThen(function()
					logger:log("trace", "multi-key update successful, committing transaction")
					return dataStoreRetry(function()
						return self._ctx.txStore:RemoveAsync(txId)
					end)
				end)
				:catch(revert)
				:andThen(function()
					logger:log("debug", "transaction committed successfully")

					-- We just technically performed a save, so let's reflect
					-- that in the Sessions.
					for _, key in keys do
						local session = self._sessions[key]
						session:setData(nextState[key])
						session.changeSet = {}
					end
				end)
				:finally(function()
					logger:log("trace", "tx finished")
				end)

			return updateAndCommitPromise
		end)
	end)
end

--[=[
	Syntactic sugar for `store:tx(keys, transformFunction):expect()`.

	See [Store:tx]
]=]
function Store:txAsync<T>(keys: { string }, transformFunction: (state: { [string]: T }) -> boolean): ()
	self:tx(keys, transformFunction):expect()
end

--[=[
	Forces an immediate save of the given key's data.
	
	:::info
	Data is automatically saved periodically, so manual saves are usually only useful in scenarios where you need to guarantee data has saved, such as ProcessReceipt.
	:::

	@error "Key not loaded" -- The key hasn't been loaded with store:load()
	@error "Store is closed" -- The store has been closed
	@return Promise -- Resolves when the save is complete
	@within Store
]=]
function Store:save(key: string): Promise.Promise
	assert(t.string(key))

	return self:_withSession(key, function(session)
		return session:save()
	end)
end

--[=[
	Syntactic sugar for `store:save(key):expect()`.

	See [Store:save]
]=]
function Store:saveAsync(key: string): ()
	self:save(key):expect()
end

--[=[
	Closes the store and unloads all active sessions.
	The store cannot be used after closing

	@return Promise -- Resolves when the store is closed
	@within Store
]=]
function Store:close(): Promise.Promise
	local logger = self._ctx.logger:extend({ method = "close" })
	logger:log("trace", "closing store")

	for _, loadPromise in self._loadPromises do
		(loadPromise :: any):cancel()
	end

	local rejections = {}

	local promises = {}
	for key in self._sessions do
		if self._unloadPromises[key] then
			logger:log("trace", "key already being unloaded", { key = key })
			table.insert(promises, self._unloadPromises[key])
		else
			logger:log("trace", "unloading key", { key = key })
			table.insert(
				promises,
				self:unload(key):catch(function(err)
					table.insert(rejections, err)
				end)
			)
		end
	end

	self._closed = true
	logger:log("trace", "store marked as closed")

	return Promise.allSettled(promises):andThen(function()
		logger:log("debug", "store closed")
		if #rejections > 0 then
			return Promise.reject(rejections)
		end
	end)
end

--[=[
	Syntactic sugar for `store:close():expect()`.

	See [Store:close]
]=]
function Store:closeAsync(): ()
	self:close():expect()
end

--[=[
	Returns the current data for the given key without loading it into the store.

	```lua
	store:peek("456123"):andThen(function(data)
		print("Current coins:", data.coins)
	end):catch(function(err)
		warn("Failed to peek data:", err)
	end)
	```

	@return Promise<T> -- Resolves with the current data
	@within Store
]=]
function Store:peek<T>(key: string): Promise.TPromise<T>
	return dataStoreRetry(function()
			return self._ctx.recordStore:GetAsync(key)
		end)
		:andThen(function(record: Types.DataStoreRecord?)
			if record == nil then
				return nil
			end
			assert(record, "luau")

			local file = record.file
			if file then
				local readParams: Files.ReadParams = {
					store = self._ctx.shardStore,
					file = file,
				}
				return Files.read(readParams)
			end

			return nil
		end)
		:andThen(function(txInfo: Types.TxInfo?)
			if txInfo == nil then
				return nil
			end
			assert(txInfo, "luau")

			local readTxParams = {
				store = self._ctx.txStore,
				txInfo = txInfo,
			}
			return Transactions.readTx(readTxParams)
		end)
end

--[=[
	Syntactic sugar for `store:peek(key):expect()`.

	See [Store:peek]
]=]
function Store:peekAsync<T>(key: string): T
	return self:peek(key):expect()
end

--[=[
	Checks if a lock is currently active for the given key.

	@return Promise<boolean>
	@within Store
]=]
function Store:probeLockActive(key: string): Promise.TPromise<boolean>
	return Locks.probeLockActive({
		storeContext = self._ctx,
		key = key,
	})
end

--[=[
	Syntactic sugar for `store:probeLockActive(key):expect()`.

	See [Store:probeLockActive]
]=]
function Store:probeLockActiveAsync(key: string): boolean
	return self:probeLockActive(key):expect()
end

--[=[
	Returns DataStoreVersionPages for the given key.

	@return Promise<DataStoreVersionPages>
	@within Store
]=]
function Store:listVersions(params: ListVersionParams): Promise.TPromise<DataStoreVersionPages>
	return dataStoreRetry(function()
		return self._ctx.recordStore:ListVersionsAsync(
			params.key,
			params.sortDirection,
			params.minDate,
			params.maxDate,
			params.pageSize
		)
	end)
end

--[=[
	Syntactic sugar for `store:listVersions(params):expect()`.

	See [Store:listVersions]
]=]
function Store:listVersionsAsync(params: ListVersionParams): DataStoreVersionPages
	return self:listVersions(params):expect()
end

--[=[
	Reads a specific version of data for the given key.

	@return Promise<T, DataStoreKeyInfo>
	@within Store
]=]
function Store:readVersion<T>(key: string, version: string): Promise.TPromise<(T, DataStoreKeyInfo)>
	return dataStoreRetry(function()
			return self._ctx.recordStore:GetVersionAsync(key, version)
		end)
		:andThen(function(record: any, keyInfo: any)
			if not record or not keyInfo then
				return Promise.reject("Record not found")
			end

			local readParams: Files.ReadParams = {
				store = self._ctx.recordStore,
				file = record.file,
			}
			return Files.read(readParams)
		end)
		:andThen(function(txInfo: Types.TxInfo)
			local readTxParams = {
				store = self._ctx.txStore,
				txInfo = txInfo,
			}

			return Transactions.readTx(readTxParams)
		end)
end

--[=[
	Syntactic sugar for `store:readVersion(key, version):expect()`.

	See [Store:readVersion]
]=]
function Store:readVersionAsync<T>(key: string, version: string): (T, DataStoreKeyInfo)
	return self:readVersion(key, version):expect()
end

return {
	createStore = createStore,
}
