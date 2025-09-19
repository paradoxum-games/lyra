--[=[
	@class Log
	@private

	Provides a structured logging implementation for the Lyra library.

	**Design:**
	- **Callback-based:** Instead of directly printing or sending logs, this module
	  uses a callback function (`logCallback`) provided during logger creation. This
	  allows the consuming application to decide how and where log messages are routed
	  (e.g., print to console, send to an external service, store in memory).
	- **Structured Context:** Log messages include a `context` table. Loggers can be
	  `extend`ed with additional context fields, which are automatically merged into
	  every subsequent log message created by that logger instance or its descendants.
	  This helps provide detailed, structured information for debugging and monitoring.
	- **Log Levels:** Supports standard log levels (`fatal`, `error`, `warn`, `info`,
	  `debug`, `trace`). A global log level can be set using `Log.setLevel` to filter
	  out messages below the desired severity.

	**Usage:**
	```lua
	local Log = require(script.Parent.Log)

	-- Set the global minimum log level (optional, defaults to "info")
	Log.setLevel("debug")

	-- Create a logger instance with a callback
	local myLogger = Log.createLogger(function(logMessage)
		print(`[{logMessage.level}] {logMessage.message}`, logMessage.context)
	end, { initialContext = "value" })

	-- Log messages
	myLogger:log("info", "User logged in", { userId = 123 })

	-- Create a logger with extended context
	local sessionLogger = myLogger:extend({ sessionId = "abc" })
	sessionLogger:log("debug", "Session data loaded")
	-- Output will include { initialContext = "value", sessionId = "abc", userId = 123 }
	-- if logged via myLogger, or { initialContext = "value", sessionId = "abc" }
	-- if logged via sessionLogger.
	```
]=]

--[=[
	Represents the different log levels available for logging messages.

	@type LogLevel "fatal" | "error" | "warn" | "info" | "debug" | "trace"
	@tag enum
	@within Log
]=]
export type LogLevel = "fatal" | "error" | "warn" | "info" | "debug" | "trace"

--[=[
	Represents a log message sent to the logger's callback function.

	@interface LogMessage
	@within Log
	.message string -- The main content of the log message.
	.level LogLevel -- The severity level of the message.
	.context { [string]: any }? -- Optional table containing additional structured context.
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

-- Ordered list of log levels from most severe to least severe.
local levels = {
	"fatal",
	"error",
	"warn",
	"info",
	"debug",
	"trace",
}

-- The main Log module table, holds global settings like the current log level.
local Log = {
	level = "info", -- Default global log level.
}

--[=[
	Sets the global minimum log level.
	Messages with a severity lower than this level will be ignored by all loggers.

	@within Log
	@param level LogLevel -- The minimum log level to allow.
	@error string -- Throws an error if the provided level is invalid.
]=]
function Log.setLevel(level: LogLevel)
	if table.find(levels, level) == nil then
		error(`Invalid log level: '{level}'`)
	end
	Log.level = level
end

-- Metatable implementing the Logger methods. (Internal)
local Logger: LoggerImpl = {} :: LoggerImpl
Logger.__index = Logger

--[=[
	Logs a message if its level is at or above the globally set log level.

	Merges the provided `context` table with the logger's persistent context
	before calling the configured `_logCallback`.

	@within Log
	@param level LogLevel -- The severity level of the message.
	@param message string -- The log message content.
	@param context { [string]: any }? -- Optional additional context specific to this log call.
]=]
function Logger:log(level: LogLevel, message: string, context: { [string]: any }?)
	-- Filter messages based on the global log level.
	if table.find(levels, level) > table.find(levels, Log.level) then
		return
	end

	-- Merge instance context with call-specific context.
	local finalContext = table.clone(self._context)
	if context then
		for key, value in context do
			finalContext[key] = value
		end
	end

	-- Call the configured log callback within a protected call to catch errors.
	local ok, result = pcall(function()
		self._logCallback({
			level = level,
			message = message,
			context = finalContext,
		})
	end)

	if not ok then
		-- If the logging callback itself errors, print a warning.
		warn(`Error in log callback: {result}`)
	end
end

--[=[
	Creates a new Logger instance that inherits the parent's callback
	but has an extended context.

	The new logger's context is a merged table containing the parent's context
	and the additional `context` provided here.

	@within Log
	@param context { [string]: any } -- The additional context fields to add.
	@return Logger -- A new Logger instance with the extended context.
]=]
function Logger:extend(context: { [string]: any }): Logger
	-- Merge existing context with the new context.
	local finalContext = table.clone(self._context)
	for key, value in context do
		finalContext[key] = value
	end

	-- Create and return a new logger instance sharing the callback but with the new context.
	return setmetatable({
		_logCallback = self._logCallback,
		_context = finalContext,
	}, Logger)
end

--[=[
	Factory function to create a new root Logger instance.

	@within Log
	@param logCallback (logMessage: LogMessage) -> () -- The function that will be called for each log message that passes the level filter. This function receives the complete `LogMessage` object including merged context.
	@param context { [string]: any }? -- Optional initial context for this logger.
	@return Logger -- A new Logger instance.
]=]
function Log.createLogger(logCallback: (logMessage: LogMessage) -> (), context: { [string]: any }?): Logger
	return setmetatable({
		_logCallback = logCallback,
		_context = context or {},
	}, Logger)
end

return Log
