--!strict

local Types = require(script.Parent.Types)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)

type PromiseQueueImpl = {
	__index: PromiseQueueImpl,

	new: (params: CreatePromiseQueueParams) -> PromiseQueue,

	_processQueue: (self: PromiseQueue) -> (),
	_addResumableBlock: (queue: PromiseQueue) -> Promise.TPromise<() -> ()>,
	_getLogContext: (self: PromiseQueue, item: QueueItem?) -> { [string]: any },

	multiQueueAdd: (queues: { PromiseQueue }, callback: () -> ()) -> Promise.Promise,
	add: (self: PromiseQueue, callback: () -> ()) -> Promise.Promise,
}

type PromiseQueueProps = {
	_queue: { QueueItem },
	_logger: Types.Logger,
	_totalItemCount: number,
}

type QueueItem = {
	id: number,
	fn: () -> (),
	resolve: (value: any) -> (),
	reject: (error: any) -> (),
	trace: string,
}

export type PromiseQueue = typeof(setmetatable({} :: PromiseQueueProps, {} :: PromiseQueueImpl))

local PromiseQueue = {} :: PromiseQueueImpl
PromiseQueue.__index = PromiseQueue

type CreatePromiseQueueParams = {
	logger: Types.Logger,
}

function PromiseQueue.new(params: CreatePromiseQueueParams): PromiseQueue
	return setmetatable({
		_queue = {},
		_logger = params.logger,
		_totalItemCount = 0,
	}, PromiseQueue) :: PromiseQueue
end

function PromiseQueue:add(callback: () -> ()): Promise.Promise
	local trace = debug.traceback(nil, 2)
	return Promise.new(function(resolve, reject, onCancel)
		self._totalItemCount += 1

		local record = {
			id = self._totalItemCount,
			fn = callback,
			resolve = resolve,
			reject = reject,
			trace = trace,
		}
		table.insert(self._queue, record)

		self._logger:log("trace", "added item to queue", self:_getLogContext())

		onCancel(function()
			local idx = table.find(self._queue, record)
			if idx then
				table.remove(self._queue, idx)
			end
		end)

		if #self._queue == 1 then
			task.spawn(function()
				self:_processQueue()
			end)
		end
	end)
end

function PromiseQueue:_processQueue()
	self._logger:log("trace", "processing queue", self:_getLogContext())
	while #self._queue > 0 do
		local item = self._queue[1]

		local deadlockWarn = task.delay(60, function()
			local ctx = self:_getLogContext(item)
			ctx.trace = item.trace
			self._logger:log("warn", "queue item taking > 60s", ctx)
		end)

		self._logger:log("trace", "processing queue item", self:_getLogContext(item))
		Promise.try(item.fn)
			:timeout(60)
			:andThen(item.resolve, function(e)
				local ctx = self:_getLogContext(item)
				ctx.error = e
				ctx.trace = item.trace

				local msg
				if Promise.Error.isKind(e, Promise.Error.Kind.TimedOut) then
					msg = "queue item timed out"
				else
					msg = "queue item failed"
				end
				self._logger:log("debug", msg, ctx)

				item.reject(`Queue item failed: {e}\nCreated at:\n{item.trace}`)
			end)
			:finally(function()
				self._logger:log("trace", "finished processing queue item", self:_getLogContext(item))

				if self._queue[1] == item then
					table.remove(self._queue, 1)
				end

				task.cancel(deadlockWarn)
			end)
			:await()
	end
end

-- Returns a promise that resolves when the queue is blocked by this. The
-- resolved value is a function to unblock the queue.
local function addResumableBlock(queue: PromiseQueue): Promise.TPromise<() -> ()>
	return Promise.new(function(resolve)
		queue:add(function()
			return Promise.new(function(resume)
				resolve(resume :: any)
			end)
		end)
	end)
end
PromiseQueue._addResumableBlock = addResumableBlock

function PromiseQueue.multiQueueAdd(queues: { PromiseQueue }, callback: () -> ()): Promise.Promise
	local trace = debug.traceback(nil, 2)
	return Promise.new(function(resolve, reject)
		local promises = Tables.map(queues, addResumableBlock)

		Promise.all(promises):andThen(function(resumes)
			Promise.try(callback)
				:andThen(resolve, function(e)
					reject(`multiQueueAdd callback failed: {e}\nCreated at:\n{trace}`)
				end)
				:finally(function()
					for _, resume in resumes do
						resume()
					end
				end)
		end)
	end)
end

function PromiseQueue:_getLogContext(item: QueueItem?): { [string]: any }
	return {
		queueLength = #self._queue,
		totalItems = self._totalItemCount,
		itemId = item and item.id,
	}
end

return PromiseQueue
