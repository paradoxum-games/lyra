--[=[
	@class PromiseQueue
	@private

	Implements a queue that processes asynchronous operations (represented by functions
	returning Promises or synchronous functions) one at a time, ensuring serial execution.

	**Purpose:** Useful for scenarios where operations on a shared resource must not
	run concurrently to prevent race conditions or ensure logical order. For example,
	processing updates to a specific player's data session.

	**Core Logic:**
	- Operations are added to the queue via the `add` method.
	- Each operation is wrapped in a `Promise`.
	- A single processing loop ([PromiseQueue:_processQueue]) runs as long as the queue is not empty.
	- The loop takes the next item, executes its associated function, and waits for
	  its Promise to resolve or reject before moving to the next item.
	- Includes timeout and deadlock detection for individual items.
	- Supports adding an operation atomically across multiple queues ([PromiseQueue:multiQueueAdd]).
]=]

local Log = require(script.Parent.Log)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)

--[=[
	Internal implementation details and methods for the PromiseQueue class.
	@interface PromiseQueueImpl
	@within PromiseQueue
	@private
	.__index PromiseQueueImpl
	.new (params: CreatePromiseQueueParams) -> PromiseQueue
	._processQueue (self: PromiseQueue) -> ()
	._addResumableBlock (queue: PromiseQueue) -> Promise<() -> ()>
	._getLogContext (self: PromiseQueue, item: QueueItem?) -> { [string]: any }
	.add (self: PromiseQueue, callback: () -> ()) -> Promise
	.multiQueueAdd (queues: { PromiseQueue }, callback: () -> ()) -> Promise -- Public static method
]=]
type PromiseQueueImpl = {
	__index: PromiseQueueImpl,
	new: (params: CreatePromiseQueueParams) -> PromiseQueue,
	_processQueue: (self: PromiseQueue) -> (),
	_addResumableBlock: (queue: PromiseQueue) -> Promise.TPromise<() -> ()>,
	_getLogContext: (self: PromiseQueue, item: QueueItem?) -> { [string]: any },
	multiQueueAdd: (queues: { PromiseQueue }, callback: () -> ()) -> Promise.Promise,
	add: (self: PromiseQueue, callback: () -> ()) -> Promise.Promise,
}

--[=[
	Internal properties stored within a PromiseQueue instance.
	@interface PromiseQueueProps
	@within PromiseQueue
	@private
	._queue { QueueItem } -- The actual queue holding items to be processed.
	._logger Log.Logger -- Logger instance for internal logging.
	._totalItemCount number -- Counter for assigning unique IDs to queue items.
]=]
type PromiseQueueProps = {
	_queue: { QueueItem },
	_logger: Log.Logger,
	_totalItemCount: number,
}

--[=[
	Represents a single item within the queue.
	@interface QueueItem
	@within PromiseQueue
	@private
	.id number -- Unique identifier for the item within this queue instance.
	.fn () -> () -- The function to execute for this item. Can be sync or return a Promise.
	.resolve (value: any) -> () -- The resolve function of the Promise returned by `add`.
	.reject (error: any) -> () -- The reject function of the Promise returned by `add`.
	.trace string -- Debug traceback captured when the item was added.
]=]
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

--[=[
	Parameters for creating a new PromiseQueue instance.
	@interface CreatePromiseQueueParams
	@within PromiseQueue
	.logger Log.Logger
]=]
type CreatePromiseQueueParams = {
	logger: Log.Logger,
}

--[=[
	Creates a new PromiseQueue instance.
	@param params -- Configuration parameters.
	@return PromiseQueue -- A new PromiseQueue object.
	@within PromiseQueue
]=]
function PromiseQueue.new(params: CreatePromiseQueueParams): PromiseQueue
	return setmetatable({
		_queue = {},
		_logger = params.logger,
		_totalItemCount = 0,
	}, PromiseQueue) :: PromiseQueue
end

--[=[
	Adds a new operation (callback function) to the end of the queue.

	The callback will be executed only after all preceding items in the queue
	have completed.

	@param callback () -> T -- The function to execute. This function can be synchronous or return a Promise. Its result or error will resolve/reject the Promise returned by this `add` call.
	@return Promise<T> -- A Promise that resolves or rejects with the result or error of the provided `callback` function once it's processed by the queue.
	@within PromiseQueue
]=]
function PromiseQueue:add(callback: () -> ()): Promise.Promise
	local trace = debug.traceback(nil, 2) -- Capture stack trace for debugging slow/failed items.
	return Promise.new(function(resolve, reject, onCancel)
		self._totalItemCount += 1

		-- Create the queue item record.
		local record = {
			id = self._totalItemCount,
			fn = callback,
			resolve = resolve,
			reject = reject,
			trace = trace,
		}
		table.insert(self._queue, record)

		self._logger:log("trace", "added item to queue", self:_getLogContext())

		-- Handle cancellation: if the returned promise is cancelled before processing,
		-- remove the item from the queue.
		onCancel(function()
			local idx = table.find(self._queue, record)
			if idx then
				table.remove(self._queue, idx)
				self._logger:log("trace", "removed cancelled item from queue", self:_getLogContext(record))
			end
		end)

		-- If this is the first item added to an empty queue, start the processing loop.
		if #self._queue == 1 then
			task.spawn(function()
				self:_processQueue()
			end)
		end
	end)
end

--[=[
	Internal function that processes items from the queue sequentially.
	It runs as long as there are items in the queue.
	@within PromiseQueue
	@private
]=]
function PromiseQueue:_processQueue()
	self._logger:log("trace", "processing queue", self:_getLogContext())
	-- Loop continues as long as items exist in the queue.
	while #self._queue > 0 do
		local item = self._queue[1] -- Get the next item from the front.

		-- Set up a warning timer for potential deadlocks or long-running items.
		-- If an item takes longer than 60 seconds, a warning is logged.
		local deadlockWarn = task.delay(60, function()
			local ctx = self:_getLogContext(item)
			ctx.trace = item.trace -- Include original call stack in warning.
			self._logger:log("warn", "queue item taking > 60s", ctx)
		end)

		self._logger:log("trace", "processing queue item", self:_getLogContext(item))
		-- Execute the item's function within a Promise context.
		Promise
			.try(item.fn)
			:timeout(60) -- Apply a 60-second timeout to the item's execution.
			:andThen(
				item.resolve, -- If successful, resolve the original promise returned by `add`.
				function(e) -- If failed (error or timeout)...
					-- Log the failure details.
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

					-- Reject the original promise with the error and traceback.
					item.reject(`Queue item failed: {e}\nCreated at:\n{item.trace}`)
				end
			)
			:finally(function()
				-- This runs regardless of success or failure.
				self._logger:log("trace", "finished processing queue item", self:_getLogContext(item))

				-- Remove the item *only if* it's still the first item.
				-- This prevents issues if an item was cancelled and removed while processing.
				if self._queue[1] == item then
					table.remove(self._queue, 1)
				end

				-- Cancel the deadlock warning timer as the item has finished.
				task.cancel(deadlockWarn)
			end)
			:await() -- Wait for the item's promise (including timeout/finally) to complete before the loop continues.
	end
	self._logger:log("trace", "finished processing queue", self:_getLogContext())
end

--[=[
	Internal helper function used by `multiQueueAdd`.
	Adds a special "blocking" item to a single queue. This item's function
	returns a Promise that only resolves when an external `resume` function is called.
	`resume` is just a Promise resolver function - calling it unblocks the queue item.

	@param queue -- The PromiseQueue instance to add the block to.
	@return Promise<() -> ()> -- A Promise that resolves with the `resume` function once the block becomes the active item in the queue.
	@within PromiseQueue
	@private
]=]
local function addResumableBlock(queue: PromiseQueue): Promise.TPromise<() -> ()>
	return Promise.new(function(outerResolve)
		-- Add an item whose function returns a promise...
		queue:add(function()
			return Promise.new(function(resume)
				-- ...that resolves the outer promise (`addResumableBlock`'s promise)
				-- with the `resume` function needed to unblock this item.
				outerResolve(resume :: any)
			end)
		end)
	end)
end
PromiseQueue._addResumableBlock = addResumableBlock -- Assign to the metatable for internal use.

--[=[
	Atomically adds a callback function to be executed across multiple queues.

	Ensures that the callback only runs when it has effectively acquired the "lock"
	(become the currently processing item) on *all* specified queues simultaneously.
	This is useful for operations that need to coordinate across multiple resources
	managed by separate queues.

	**Mechanism:**
	1. Uses `_addResumableBlock` to add a blocking item to each queue.
	2. Waits for all these blocking items to become active (i.e., all `_addResumableBlock`
	   promises resolve, returning their `resume` functions).
	3. Once all queues are blocked, executes the provided `callback`.
	4. After the `callback` finishes (successfully or with an error), calls all the
	   `resume` functions to unblock all the queues.

	@param queues -- A table array of PromiseQueue instances to coordinate.
	@param callback -- The function to execute once all queues are ready.
	@return Promise -- A Promise that resolves/rejects with the result/error of the `callback`.
	@within PromiseQueue
]=]
function PromiseQueue.multiQueueAdd(queues: { PromiseQueue }, callback: () -> ()): Promise.Promise
	local trace = debug.traceback(nil, 2)
	return Promise.new(function(resolve, reject)
		-- Add a resumable block to each queue.
		local promises = Tables.map(queues, addResumableBlock)

		-- Wait for all blocks to be added and become active.
		Promise.all(promises):andThen(function(resumes)
			-- All queues are now blocked at our added item. Execute the callback.
			Promise.try(callback)
				:andThen(resolve, function(e) -- Handle callback success/failure
					reject(`multiQueueAdd callback failed: {e}\nCreated at:\n{trace}`)
				end)
				:finally(function()
					-- Unblock all queues regardless of callback outcome.
					for _, resume in resumes do
						resume()
					end
				end)
		end)
	end)
end

--[=[
	Internal helper to generate a context table for logging.
	@param item -- (Optional) The QueueItem currently being processed.
	@return { [string]: any } -- A table containing common context fields like queue length and item ID.
	@within PromiseQueue
	@private
]=]
function PromiseQueue:_getLogContext(item: QueueItem?): { [string]: any }
	return {
		queueLength = #self._queue,
		totalItems = self._totalItemCount,
		itemId = item and item.id,
	}
end

return PromiseQueue
