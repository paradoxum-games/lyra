--!strict

local HttpService = game:GetService("HttpService")

local Constants = require(script.Parent.Constants)
local Files = require(script.Parent.Files)
local Locks = require(script.Parent.Locks)
local Migrations = require(script.Parent.Migrations)
local PromiseQueue = require(script.Parent.PromiseQueue)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)
local t = require(script.Parent.Parent:WaitForChild("t").lib.ts)
local Types = require(script.Parent.Types)
local Transactions = require(script.Parent.Transactions)
local dataStoreRetry = require(script.Parent.dataStoreRetry)
local noYield = require(script.Parent.noYield)

type SessionImpl<T> = {
	__index: SessionImpl<T>,

	load: (params: LoadSessionParams<T>) -> Promise.TPromise<Session<T>>,

	updateRecord: (self: Session<T>) -> Promise.TPromise<any>,
	writeRecord: (self: Session<T>, txInfo: Types.TxInfo) -> Promise.TPromise<any>,

	isSaved: (self: Session<T>) -> boolean,

	setData: (self: Session<T>, data: T) -> (),
	mutateKey: (self: Session<T>, newData: T) -> (),

	startAutosaving: (self: Session<T>) -> (),
	stopAutosaving: (self: Session<T>) -> (),

	unload: (self: Session<T>) -> Promise.Promise,
	get: (self: Session<T>) -> Promise.TPromise<T>,
	update: (self: Session<T>, transformFunction: (data: T) -> boolean) -> Promise.TPromise<boolean>,
	save: (self: Session<T>) -> Promise.Promise,
}

type SessionProps<T> = {
	_cleanupAutosave: (() -> ())?,

	key: string,
	ctx: Types.StoreContext<T>,
	lockHandle: Locks.LockHandle,

	userIds: { number }?,

	data: T?,
	frozenData: T?,
	appliedMigrations: { string },

	changeSet: { [string]: true },

	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	queue: PromiseQueue.PromiseQueue,
	txLockPromise: Promise.Promise?,

	closed: boolean,
	unloadPromise: Promise.Promise?,

	keyInfo: DataStoreKeyInfo?,

	logger: Types.Logger,
}

export type Session<T> = typeof(setmetatable({} :: SessionProps<T>, {} :: SessionImpl<T>))

type LoadSessionParams<T> = {
	key: string,
	storeContext: Types.StoreContext<T>,
	userIds: { number }?,
}
local loadSessionParamsCheck = t.strictInterface({
	key = t.string,
	storeContext = t.any,
	userIds = t.optional(t.array(t.number)),
})

export type LoadParams = {
	storeContext: Types.StoreContext<any>,
	key: string,
}

export type LoadResult = {
	data: any,
	appliedMigrations: { string },
	orphanedFiles: { Types.File },
	currentFile: Types.File?,
	keyInfo: DataStoreKeyInfo?,
}

local function load(params: LoadParams): any
	local ctx = params.storeContext
	local key = params.key

	local logger = ctx.logger:extend({ method = "load", key = params.key })
	logger:log("trace", `loading key`)

	local appliedMigrations: { string } = Migrations.getStepNames(ctx.migrationSteps)
	local orphanedFiles: { Types.File } = {}
	local currentFile: Types.File?
	local keyInfo: DataStoreKeyInfo?

	return dataStoreRetry(function()
			return ctx.recordStore:GetAsync(key)
		end)
		:andThen(function(record: Types.DataStoreRecord?, _keyInfo: DataStoreKeyInfo?)
			logger:log("trace", "got record")
			if record == nil then
				record = {} :: Types.DataStoreRecord
			end
			assert(record, "luau")

			keyInfo = _keyInfo
			if record.appliedMigrations then
				appliedMigrations = record.appliedMigrations
			end

			if record.orphanedFiles then
				orphanedFiles = record.orphanedFiles
				ctx.orphanedFileQueue:markFiles(key, record.orphanedFiles)
			end

			local file = record.file
			if file then
				if Files.isLargeFile(file) then
					currentFile = file
				end

				logger:log("trace", "reading file", { file = HttpService:JSONEncode(file) })
				local readParams: Files.ReadParams = {
					store = ctx.shardStore,
					file = file,
				}
				return Files.read(readParams)
			end

			logger:log("trace", "no file")

			return nil :: any
		end)
		:andThen(function(txInfo: Types.TxInfo?): any?
			if txInfo then
				logger:log("trace", "got txInfo", { txInfo = txInfo })

				local readTxParams = {
					store = ctx.txStore,
					txInfo = txInfo,
				}
				return Transactions.readTx(readTxParams)
			end

			logger:log("trace", "no txInfo")

			return nil
		end)
		:andThen(function(data: any?)
			if data ~= nil then
				logger:log("trace", "got data")
				return data
			end

			local importLegacyData = ctx.importLegacyData
			if importLegacyData == nil then
				logger:log("trace", "no data, no importLegacyData")
				return nil
			end

			logger:log("trace", "no data, importing legacy data")
			local importOk, importResult = pcall(importLegacyData, key)
			if not importOk then
				logger:log("error", "failed to import legacy data", { error = importResult })
				return Promise.reject(`Failed to import legacy data for key {key}: {importResult}`)
			end

			local oldData = importResult
			if oldData == nil then
				return nil
			else
				appliedMigrations = {}
				logger:log("trace", "imported legacy data", { oldData = oldData })
				return oldData
			end
		end)
		:andThen(function(data: any?)
			if data == nil then
				logger:log("trace", "no data, using template")
				data = Tables.copyDeep(ctx.template)
			end
			assert(data, "luau")

			if #ctx.migrationSteps > 0 then
				logger:log("debug", "applying migrations")
				local migrationParams: Migrations.ApplyParams = {
					logger = logger:extend({ component = "Migrations" }),
					data = data,
					steps = ctx.migrationSteps,
					appliedMigrations = appliedMigrations,
				}

				return Migrations.apply(migrationParams):andThen(function(result: Migrations.ApplyResult)
					appliedMigrations = result.appliedMigrations
					logger:log("trace", "migrations applied", { data = data, appliedMigrations = appliedMigrations })
					return result.data
				end)
			end

			logger:log("trace", "data loaded")
			return data
		end)
		:andThen(function(data)
			logger:log("trace", "load done")
			local loadResult: LoadResult = {
				data = data,
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

local function createSession<T>(params: CreateSessionParams): Session<T>
	local logger = params.storeContext.logger:extend({ key = params.key })

	local queue = PromiseQueue.new({
		logger = logger:extend({ component = "PromiseQueue" }),
	})

	local props: SessionProps<T> = {
		key = params.key,
		ctx = params.storeContext,
		lockHandle = params.lockHandle,

		userIds = params.userIds,

		data = nil,
		frozenData = nil,
		appliedMigrations = params.appliedMigrations,

		changeSet = {},

		orphanedFiles = params.orphanedFiles,
		currentFile = params.currentFile,

		queue = queue,
		txLockPromise = nil,

		closed = false,
		unloadPromise = nil,

		keyInfo = params.keyInfo,
		logger = logger,
	}

	return setmetatable(props, Session) :: Session<T>
end

function Session.load<T>(params: LoadSessionParams<T>): Promise.TPromise<Session<T>>
	assert(loadSessionParamsCheck(params))

	local ctx = params.storeContext
	local logger = ctx.logger:extend({ method = "load", key = params.key })

	local acquireLockParams: Locks.AcquireLockParams = {
		storeContext = ctx,
		key = params.key,
		acquireAttempts = Constants.LOCK_ACQUIRE_ATTEMPTS,
		duration = Constants.LOCK_DURATION_SECONDS,
		refreshInterval = Constants.LOCK_REFRESH_INTERVAL_SECONDS,
	}

	return Locks.acquireLock(acquireLockParams):andThen(function(lockHandle)
		local loadParams = {
			storeContext = ctx,
			key = params.key,
		}

		return load(loadParams):andThen(function(loadResult)
			if not lockHandle.isLocked() then
				logger:log("error", "lock was lost while loading key")
				return Promise.reject("Lock was lost while loading key")
			end

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

			lockHandle.onLockLost(function()
				logger:log("warn", "lock was lost, stopping autosave")
				session.closed = true
				session:stopAutosaving()
				session.unloadPromise = Promise.resolve()
			end)

			logger:log("trace", "loaded key", { data = loadResult.data })
			session:mutateKey(loadResult.data)

			return session :: any
		end):finally(function(status): ()
			if status ~= (Promise :: any).Status.Resolved then
				logger:log("trace", "failed to load key, releasing lock")
				lockHandle.release():catch(function(e)
					logger:log("warn", "failed to release lock", { error = e })
				end)
			end
		end)
	end)
end

function Session:updateRecord(): Promise.TPromise<any>
	local logger = self.logger:extend({ method = "updateRecord" })
	logger:log("trace", "updateRecord called")

	if self:isSaved() then
		logger:log("trace", "no changes, returning")
		return Promise.resolve()
	end

	local txInfo = { committedData = self.data }

	logger:log("trace", "writing record", { txInfo = txInfo })
	return self:writeRecord(txInfo)
end

function Session:writeRecord(txInfo: Types.TxInfo): Promise.TPromise<any>
	local logger = self.logger:extend({ method = "writeRecord" })
	logger:log("trace", "writeRecord called")

	local function orphanFile(file: Types.File?)
		if file ~= nil and Files.isLargeFile(file) then
			table.insert(self.orphanedFiles, file)
			self.ctx.orphanedFileQueue:markFile(self.key, file)
		end
	end

	local writeParams: Files.WriteParams = {
		store = self.ctx.shardStore,
		data = txInfo,
		maxShardSize = Constants.MAX_CHUNK_SIZE,
		key = self.key,
		userIds = self.userIds,
	}

	logger:log("trace", "writing file", { writeParams = writeParams })

	return Files.write(writeParams)
		:catch(function(err: Files.WriteError)
			logger:log("error", "failed to write shards", { error = err.error })

			orphanFile(err.file)

			return Promise.reject(err.error)
		end)
		:andThen(function(file)
			logger:log("trace", "file written", { file = file })

			if not self.lockHandle.isLocked() then
				logger:log("error", "lock was lost while writing file")
				orphanFile(file)
				return Promise.reject("lock was lost while writing file")
			end

			local stagedOrphanedFiles = table.clone(self.orphanedFiles)
			table.insert(stagedOrphanedFiles, self.currentFile :: any)

			local record = {
				appliedMigrations = self.appliedMigrations,
				file = file,
				orphanedFiles = stagedOrphanedFiles,
			}

			logger:log("trace", "writing record", { record = record })
			return dataStoreRetry(function()
					return self.ctx.recordStore:SetAsync(self.key, record, self.userIds)
				end)
				:andThen(function()
					logger:log("trace", "record written")

					orphanFile(self.currentFile)
					self.currentFile = if Files.isLargeFile(file) then file else nil

					return record
				end)
				:catch(function(err)
					logger:log("error", "failed to write record", { error = err })

					orphanFile(file)

					return Promise.reject(err)
				end)
		end)
end

function Session:isSaved(): boolean
	return next(self.changeSet) == nil
end

function Session:setData(data: any): ()
	local mutationId = HttpService:GenerateGUID(false)
	self.changeSet[mutationId] = true
	self.data = data
	self.frozenData = Tables.freezeDeep(data :: any)
end

function Session:mutateKey(newData: any): ()
	local oldData = self.frozenData

	self:setData(newData)

	for _, callback in self.ctx.changedCallbacks do
		task.spawn(callback, self.key, self.frozenData, oldData)
	end
end

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

	local stop = false

	task.spawn(function()
		while true do
			task.wait(Constants.AUTOSAVE_INTERVAL_SECONDS)
			if self.closed or stop then
				break
			end

			local ok, err = self:save():await()
			if not ok then
				logger:log("warn", "failed to autosave key", { error = err })
			end
		end
	end)

	self._cleanupAutosave = function()
		logger:log("trace", "cleaning up autosave")
		stop = true
		self._cleanupAutosave = nil
	end
end

function Session:stopAutosaving(): ()
	if self._cleanupAutosave then
		self._cleanupAutosave()
	end
end

function Session:unload(): Promise.Promise
	local logger = self.logger:extend({ method = "unload" })
	logger:log("trace", "unload called")

	if self.unloadPromise then
		logger:log("trace", "unload already in progress")
		return self.unloadPromise
	end

	self.closed = true
	self:stopAutosaving()

	logger:log("trace", "queueing unload")
	self.unloadPromise = self.queue
		:add(function()
			logger:log("trace", "updating record before unloading")
			return self:updateRecord()
		end)
		:andThenReturn(nil)
		:finally(function()
			logger:log("trace", "releasing lock")
			return self.lockHandle.release():catch(function(e)
				logger:log("warn", "failed to release lock", { error = e })
			end)
		end)

	return self.unloadPromise :: any
end

function Session:get<T>(): Promise.TPromise<T>
	return Promise.resolve(self.frozenData) :: any
end

function Session:update<T>(transformFunction: (data: T) -> boolean): Promise.TPromise<boolean>
	assert(t.callback(transformFunction))

	local logger = self.logger:extend({ method = "update" })
	logger:log("trace", "update called")

	if self.closed then
		logger:log("warn", "Session is closed, skipping update")
		return Promise.reject("Session is closed")
	end

	return Promise.new(function(resolve, reject)
		while self.txLockPromise ~= nil do
			self.txLockPromise:await()
		end
		logger:log("trace", `updating key`)

		local currentData = self.data
		local nextData = Tables.copyDeep(currentData)

		local transformOk, result = pcall(noYield, transformFunction, nextData :: any)
		if not transformOk then
			logger:log("error", "transformFunction failed", { error = result })
			return reject(`transformFunction failed: {result}`)
		end

		if typeof(result) ~= "boolean" then
			logger:log("error", "transformFunction must return a boolean")
			return reject("transformFunction must return a boolean")
		end

		if result == false then
			logger:log("trace", "transformFunction returned false, skipping update")
			return resolve(false)
		end

		if self.ctx.disableReferenceProtection == false then
			-- We deep copy here to prevent references to internal state from being
			-- leaked. If we didn't, the transform function could modify the state
			-- after it runs, which shouldn't be allowed.
			nextData = Tables.copyDeep(nextData)
		end

		local schemaOk, err = self.ctx.schema(nextData :: any)
		if not schemaOk then
			logger:log("error", "schema validation failed", { error = err })
			return reject(`Store:update schema validation failed: {err}`)
		end

		if Tables.equalsDeep(nextData :: any, currentData :: any) then
			return resolve(true)
		end

		self:mutateKey(nextData)

		logger:log("trace", "update succeeded")

		return resolve(true)
	end)
end

function Session:save(): Promise.Promise
	local logger = self.logger:extend({ method = "save" })
	logger:log("trace", "save called")

	if self.closed then
		logger:log("warn", "Session is closed, skipping save")
		return Promise.reject("Session is closed")
	end
	if self:isSaved() then
		logger:log("trace", "no changes, returning")
		return Promise.resolve()
	end

	local changes = table.clone(self.changeSet)

	logger:log("trace", "queueing save")
	return self.queue:add(function()
		logger:log("trace", "save task running")

		local changesWereSaved = true
		for id in self.changeSet do
			if changes[id] then
				changesWereSaved = false
				break
			end
		end

		if changesWereSaved then
			logger:log("trace", "changes were saved by another task, returning")
			return Promise.resolve()
		end

		changes = table.clone(self.changeSet)

		logger:log("trace", "saving changes", { changes = changes })
		return self:updateRecord():andThen(function()
			for id in changes do
				self.changeSet[id] = nil
			end

			logger:log("trace", "changes saved", { latestChanges = self.changeSet })
		end)
	end)
end

return Session
