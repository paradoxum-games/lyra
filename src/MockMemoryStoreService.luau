--!strict

local HttpService = game:GetService("HttpService")

local Tables = require(script.Parent.Tables)

local MAX_QUEUE_SIZE = 30
local RATE_LIMITS = {
	GetAsync = { Base = 100, PlayerMultiplier = 10 },
	SetAsync = { Base = 100, PlayerMultiplier = 10 },
	UpdateAsync = { Base = 100, PlayerMultiplier = 10 },
	RemoveAsync = { Base = 100, PlayerMultiplier = 10 },
}

local MAX_KEY_LENGTH = 128
local MAX_VALUE_SIZE = 32 * 1024 -- 32KB
local MAX_UPDATE_RETRIES = 3
local MAX_EXPIRATION = 3888000 -- 45 days in seconds

local function getNow()
	return DateTime.now().UnixTimestampMillis
end

local function getLatencyForRequest(service: any, requestType: string): number
	if service._latencyByRequestType[requestType] then
		return service._latencyByRequestType[requestType]
	end

	if service._randomLatencyRange then
		local min = service._randomLatencyRange.min
		local max = service._randomLatencyRange.max
		return min + math.random() * (max - min)
	end

	return service._globalLatency or 0.1
end

local function shouldSimulateError(service: any, requestType: string): (boolean, string?)
	if #service.queuedErrors[requestType] > 0 then
		return true, table.remove(service.queuedErrors[requestType], 1)
	end

	if service._errorRates[requestType] and math.random() < service._errorRates[requestType] then
		return true, "InternalError: random error simulation"
	end

	if service._simulateThrottling then
		return true, "Throttled: MemoryStore request was throttled, try again later"
	end

	if service._simulateTimeout then
		return true, "Timeout: MemoryStore request timed out"
	end

	return false, nil
end

local function doLatency(service: any, requestType: string)
	local latency = getLatencyForRequest(service, requestType)
	if latency > 0 then
		task.wait(latency)
	end
end

local function doRateLimitAndQueue(service: any, requestType: string)
	local queue = service.requestQueues[requestType]
	local limitData = RATE_LIMITS[requestType]
	local budget = service._customBudgets[requestType]
	if not budget then
		local currentPlayers = 15
		budget = limitData.Base + (currentPlayers * limitData.PlayerMultiplier)
	end

	if #queue >= budget then
		error("TotalRequestsOverLimit", 0)
	end

	if #queue >= MAX_QUEUE_SIZE then
		error("RequestThrottled", 0)
	end

	if service._forcedThrottles[requestType] then
		local throttleInfo = service._forcedThrottles[requestType]
		if throttleInfo.endTime > os.time() then
			error("MemoryStore request is currently throttled", 0)
		else
			service._forcedThrottles[requestType] = nil
		end
	end

	table.insert(queue, true)
	doLatency(service, requestType)
	local fn = table.remove(queue, 1)

	local shouldError, errorMessage = shouldSimulateError(service, requestType)
	if shouldError then
		error(errorMessage, 0)
	end

	if typeof(fn) == "function" then
		fn()
	end
end

local function enforceKeyLimits(key: string)
	if typeof(key) ~= "string" then
		error("InvalidRequest: key must be a string", 0)
	end
	if #key == 0 then
		error("InvalidRequest: key cannot be empty", 0)
	end
	if #key > MAX_KEY_LENGTH then
		error("InvalidRequest: key length exceeds limit", 0)
	end
end

local function enforceValueLimits(value: any)
	if value == nil then
		return
	end

	local success, encoded = pcall(function()
		return HttpService:JSONEncode(value)
	end)

	if not success then
		error("InvalidRequest: value cannot be encoded to JSON", 0)
	end

	if #encoded > MAX_VALUE_SIZE then
		error("ItemValueSizeTooLarge", 0)
	end
end

local function enforceExpirationLimits(expiration: number)
	if typeof(expiration) ~= "number" then
		error("InvalidRequest: expiration must be a number", 0)
	end
	if expiration < 0 then
		error("InvalidRequest: expiration must be >= 0", 0)
	end
	if expiration > MAX_EXPIRATION then
		error("InvalidRequest: expiration exceeds maximum", 0)
	end
end

local function getScopedData(self: any)
	local hashMap = self.service.mockData[self.name]
	if not hashMap then
		hashMap = {}
		self.service.mockData[self.name] = hashMap
	end
	return hashMap
end

local function isExpired(entry: any): boolean
	if not entry or not entry.expiration then
		return true
	end
	return getNow() > entry.expiration
end

local MockHashMap = {}

function MockHashMap:GetAsync(key: string): any?
	enforceKeyLimits(key)

	doRateLimitAndQueue(self.service, "GetAsync")

	local scopedData = getScopedData(self)
	local entry = scopedData[key]

	if isExpired(entry) then
		scopedData[key] = nil
		return nil
	end

	return entry.value
end

function MockHashMap:SetAsync(key: string, value: any, expiration: number): boolean
	enforceKeyLimits(key)
	enforceValueLimits(value)
	enforceExpirationLimits(expiration)

	doRateLimitAndQueue(self.service, "SetAsync")

	local scopedData = getScopedData(self)
	local serialized = HttpService:JSONEncode(value)
	if serialized == nil then
		return false
	end

	scopedData[key] = {
		value = value,
		expiration = getNow() + expiration * 1000,
	}

	return true
end

function MockHashMap:UpdateAsync(key: string, transformFunction: (any?) -> any?, expiration: number): any?
	enforceKeyLimits(key)
	enforceExpirationLimits(expiration)

	doRateLimitAndQueue(self.service, "UpdateAsync")

	local scopedData = getScopedData(self)
	local retries = 0

	while retries < MAX_UPDATE_RETRIES do
		local entry = scopedData[key]
		local currentValue = nil

		if not isExpired(entry) then
			currentValue = Tables.copyDeep(entry.value)
		end

		local success, newValue = pcall(transformFunction, currentValue)
		if not success then
			error("TransformCallbackFailed", 0)
		end

		if newValue == nil then
			return nil
		end

		enforceValueLimits(newValue)

		if entry and not isExpired(entry) and not Tables.equalsDeep(entry.value, currentValue) then
			retries += 1
			if retries >= MAX_UPDATE_RETRIES then
				error("DataUpdateConflict", 0)
			end
			continue
		end

		scopedData[key] = {
			value = newValue,
			expiration = getNow() + expiration * 1000,
		}

		return newValue
	end

	error("UpdateConflict: Exceeded max number of retries", 0)
end

function MockHashMap:RemoveAsync(key: string)
	enforceKeyLimits(key)

	doRateLimitAndQueue(self.service, "RemoveAsync")

	local scopedData = getScopedData(self)
	scopedData[key] = nil
end

local function createMockHashMap(service: any, name: string): any
	return setmetatable({
		service = service,
		name = name,
	}, { __index = service.mockHashMapMeta })
end

local function new(): MemoryStoreService
	local mockHashMapMeta = table.clone(MockHashMap)
	mockHashMapMeta.__index = mockHashMapMeta

	local tbl = {
		mockData = {},
		hashMaps = {},
		mockHashMapMeta = mockHashMapMeta,
		requestQueues = {
			GetAsync = {},
			SetAsync = {},
			UpdateAsync = {},
			RemoveAsync = {},
		},
		queuedErrors = {
			GetAsync = {},
			SetAsync = {},
			UpdateAsync = {},
			RemoveAsync = {},
		},

		_globalLatency = nil,
		_latencyByRequestType = {},
		_randomLatencyRange = nil,
		_errorRates = {},
		_simulateThrottling = false,
		_simulateTimeout = false,
		_customBudgets = {},
		_forcedThrottles = {},
	}

	tbl.GetHashMap = function(self, name: string): any
		if not self.hashMaps[name] then
			self.hashMaps[name] = createMockHashMap(self, name)
		end
		return self.hashMaps[name]
	end

	return (tbl :: any) :: MemoryStoreService
end

return {
	new = new,

	mockHashMapMethod = function(service: any, method: string, jest: any)
		local real = service.mockHashMapMeta[method]
		local mock, fn = jest.fn(real)
		service.mockHashMapMeta[method] = fn
		return mock, real
	end,

	setGlobalLatency = function(service: any, seconds: number)
		service._globalLatency = seconds
	end,
	setLatencyForRequestType = function(service: any, requestType: string, seconds: number)
		service._latencyByRequestType[requestType] = seconds
	end,
	setRandomLatency = function(service: any, minSeconds: number, maxSeconds: number)
		service._randomLatencyRange = { min = minSeconds, max = maxSeconds }
	end,
	queueError = function(service: any, requestType: string, errorMessage: string, count: number?)
		for _ = 1, count or 1 do
			table.insert(service.queuedErrors[requestType], errorMessage)
		end
	end,
	setErrorRate = function(service: any, requestType: string, rate: number)
		service._errorRates[requestType] = rate
	end,
	simulateThrottling = function(service: any, enabled: boolean)
		service._simulateThrottling = enabled
	end,
	simulateTimeout = function(service: any, enabled: boolean)
		service._simulateTimeout = enabled
	end,
	setRequestBudget = function(service: any, requestType: string, budget: number)
		service._customBudgets[requestType] = budget
	end,
	forceThrottle = function(service: any, requestType: string, duration: number)
		service._forcedThrottles[requestType] = {
			endTime = os.time() + duration,
		}
	end,

	snapshot = function(service: any)
		return HttpService:JSONEncode({
			mockData = service.mockData,
		})
	end,
	restore = function(service: any, snapshot: string)
		local decoded = HttpService:JSONDecode(snapshot)
		service.mockData = decoded.mockData
	end,
}
