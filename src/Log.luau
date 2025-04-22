--!strict

local Types = require(script.Parent.Types)

local levels = {
	"fatal",
	"error",
	"warn",
	"info",
	"debug",
	"trace",
}

local Log = {
	level = "info",
}

function Log.setLevel(level: Types.LogLevel)
	if table.find(levels, level) == nil then
		error("Invalid log level")
	end
	Log.level = level
end

local Logger: Types.LoggerImpl = {} :: Types.LoggerImpl
Logger.__index = Logger

function Logger:log(level: Types.LogLevel, message: string, context: { [string]: any }?)
	if table.find(levels, level) > table.find(levels, Log.level) then
		return
	end

	local finalContext = table.clone(self._context)
	if context then
		for key, value in context do
			finalContext[key] = value
		end
	end

	local ok, result = pcall(function()
		self._logCallback({
			level = level,
			message = message,
			context = finalContext,
		})
	end)

	if not ok then
		warn(`Error logging message: {result}`)
	end
end

function Logger:extend(context: { [string]: any }): Types.Logger
	local finalContext = table.clone(self._context)
	for key, value in context do
		finalContext[key] = value
	end

	return setmetatable({
		_logCallback = self._logCallback,
		_context = finalContext,
	}, Logger)
end

function Log.createLogger(logCallback: (logMessage: Types.LogMessage) -> (), context: { [string]: any }?): Types.Logger
	return setmetatable({
		_logCallback = logCallback,
		_context = context or {},
	}, Logger)
end

return Log
