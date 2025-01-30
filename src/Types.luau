--!strict

--[=[
	Common types shared among different modules.

	@class Types
]=]

local t = require(script.Parent.Parent:WaitForChild("t").lib.ts)

export type PatchOperation =
	{ op: "add", path: string, value: any }
	| { op: "replace", path: string, value: any }
	| { op: "remove", path: string }
export type TxPatch = { PatchOperation }

export type TxInfo = {
	committedData: any,
	txId: string?,
	txPatch: TxPatch?,
}

export type File = {
	data: any,
} & {
	shard: string,
	count: number,
}

export type LockInfo = {
	id: string,
	expiry: number,
}

export type DataStoreRecord = {
	appliedMigrations: { string },
	file: File,
	orphanedFiles: {},
}

export type OrphanedFileQueueItem = {
	key: string,
	file: File,
	beingProcessed: boolean,
}

export type OrphanedFileQueueImpl = {
	__index: OrphanedFileQueueImpl,
	new: () -> OrphanedFileQueue,
	markFile: (self: OrphanedFileQueue, key: string, file: File) -> (),
	markFiles: (self: OrphanedFileQueue, key: string, files: { File }) -> (),
	_processQueueItems: (self: OrphanedFileQueue) -> (),
}

type OrphanedFileQueueProps = {
	queue: { OrphanedFileQueueItem },
	processQueueItem: ((item: OrphanedFileQueueItem) -> boolean)?,
}

export type OrphanedFileQueue = typeof(setmetatable({} :: OrphanedFileQueueProps, {} :: OrphanedFileQueueImpl))

--[=[
	A migration step

	@interface MigrationStep
	.name string -- The name of the migration step
	.apply (data: { [string]: any }) -> { [string]: any } -- The function to apply the migration step

	@within Types
]=]
export type MigrationStep = {
	name: string,
	apply: (data: { [string]: any }) -> { [string]: any },
}

export type StoreContext<T> = {
	name: string,
	template: T,
	schema: (value: any) -> (boolean, string?),

	migrationSteps: { MigrationStep },
	importLegacyData: ((key: string) -> any?)?,

	dataStoreService: DataStoreService,
	memoryStoreService: MemoryStoreService,

	orphanedFileQueue: OrphanedFileQueue,
	changedCallbacks: { (key: string, newData: T, oldData: T?) -> () -> () },
	logger: Logger,
	onLockLost: ((key: string) -> ())?,

	recordStore: DataStore,
	shardStore: DataStore,
	txStore: DataStore,
	lockHashMap: MemoryStoreHashMap,

	disableReferenceProtection: boolean,
}

local txInfoCheck = t.some(
	t.strictInterface({ committedData = t.any }),
	t.strictInterface({ committedData = t.any, txId = t.string, txPatch = t.any })
)
local fileCheck = t.some(t.strictInterface({ data = t.any }), t.strictInterface({ shard = t.string, count = t.number }))

--[=[
	An enum value representing a log level.

	@interface LogLevel
	.fatal "fatal"
	.error "error"
	.warn "warn"
	.info "info"
	.debug "debug"
	.trace "trace"

	@tag enum
	@within Types
]=]
export type LogLevel = "fatal" | "error" | "warn" | "info" | "debug" | "trace"

--[=[
	Represents a log message.

	@interface LogMessage
	.message string
	.level LogLevel
	.context { [string]: any }?

	@within Types
]=]
export type LogMessage = {
	message: string,
	level: LogLevel,
	context: { [string]: any }?,
}

export type LoggerImpl = {
	__index: LoggerImpl,

	log: (self: Logger, level: LogLevel, message: string, context: { [string]: any }?) -> (),
	extend: (self: Logger, context: { [string]: any }) -> Logger,
}

export type LoggerProps = {
	_logCallback: (logMessage: LogMessage) -> (),
	_context: { [string]: any },
}

export type Logger = typeof(setmetatable({} :: LoggerProps, {} :: LoggerImpl))

export type RetryHandle<T> = {
	promise: T,
	cancel: () -> (),
}

return {
	txInfoCheck = txInfoCheck,
	fileCheck = fileCheck,
}
