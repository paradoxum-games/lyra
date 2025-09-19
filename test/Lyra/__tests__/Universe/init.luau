type TraceViewImpl = {
	__index: TraceViewImpl,

	new: (fullTrace: { TraceEvent }) -> TraceView,
	filter: (self: TraceView, predicate: (event: TraceEvent) -> boolean) -> TraceView,
	expand: (self: TraceView, nBefore: number, nAfter: number?) -> TraceView,
	before: (self: TraceView, n: number) -> TraceView,
	after: (self: TraceView, n: number) -> TraceView,
	first: (self: TraceView) -> TraceView,
	last: (self: TraceView) -> TraceView,
	at: (self: TraceView, i: number) -> TraceView,
	get: (self: TraceView) -> { TraceEvent },
	count: (self: TraceView) -> number,
	map: (self: TraceView, transformFn: (event: TraceEvent) -> any) -> { any },
	groupBy: (self: TraceView, keyFn: (event: TraceEvent) -> any) -> { [any]: { TraceEvent } },
	firstEvent: (self: TraceView) -> TraceEvent?,
	lastEvent: (self: TraceView) -> TraceEvent?,
}

type TraceViewProps = {
	_fullTrace: { TraceEvent },
	_resultIndices: { number }, -- Indices of events in the full trace that match the current view
}

type TraceView = typeof(setmetatable({} :: TraceViewProps, {} :: TraceViewImpl))

local TraceView = {} :: TraceViewImpl
TraceView.__index = TraceView

function TraceView.new(fullTrace): TraceView
	local o = {
		_fullTrace = fullTrace,
		_resultIndices = {},
	}
	setmetatable(o, TraceView)
	return o
end

-- Private helper to get an event by its index in the full trace
function TraceView:_getEvent(index)
	return self._fullTrace[index]
end

-- Chaining Methods (return self)

function TraceView:filter(predicate): TraceView
	local newIndices = {}
	for _, index in self._resultIndices do
		if predicate(self:_getEvent(index)) then
			table.insert(newIndices, index)
		end
	end
	self._resultIndices = newIndices
	return self
end

function TraceView:expand(nBefore, nAfter): TraceView
	-- If only one argument is given, use it for both before and after
	nBefore = nBefore or 0
	nAfter = nAfter or nBefore

	if #self._resultIndices == 0 then
		return self
	end

	local expandedSet = {} -- Use a set to handle overlaps automatically
	local traceLen = #self._fullTrace

	for _, index in self._resultIndices do
		local startIndex = math.max(1, index - nBefore)
		local endIndex = math.min(traceLen, index + nAfter)
		for i = startIndex, endIndex do
			expandedSet[i] = true
		end
	end

	-- Convert the set back to a sorted list of indices
	local newIndices = {}
	for index in expandedSet do
		table.insert(newIndices, index)
	end
	table.sort(newIndices)

	self._resultIndices = newIndices
	return self
end

function TraceView:before(n): TraceView
	return self:expand(n, 0)
end

function TraceView:after(n): TraceView
	return self:expand(0, n)
end

function TraceView:first(): TraceView
	if #self._resultIndices > 0 then
		self._resultIndices = { self._resultIndices[1] }
	end
	return self
end

function TraceView:last(): TraceView
	if #self._resultIndices > 0 then
		self._resultIndices = { self._resultIndices[#self._resultIndices] }
	end
	return self
end

function TraceView:at(i): TraceView
	if self._resultIndices[i] then
		self._resultIndices = { self._resultIndices[i] }
	else
		self._resultIndices = {}
	end
	return self
end

-- Terminating Methods (return data)

function TraceView:get()
	local results = {}
	for _, index in self._resultIndices do
		table.insert(results, self:_getEvent(index))
	end
	return results
end

function TraceView:count()
	return #self._resultIndices
end

function TraceView:map(transformFn)
	local results = {}
	for _, index in self._resultIndices do
		table.insert(results, transformFn(self:_getEvent(index)))
	end
	return results
end

function TraceView:groupBy(keyFn)
	local groups = {}
	for _, index in self._resultIndices do
		local event = self:_getEvent(index)
		local key = keyFn(event)
		if not groups[key] then
			groups[key] = {}
		end
		table.insert(groups[key], event)
	end
	return groups
end

function TraceView:firstEvent()
	return self:first():get()[1]
end

function TraceView:lastEvent()
	return self:last():get()[1]
end

type UniverseImpl = {
	__index: UniverseImpl,

	new: (config: UniverseConfig) -> Universe,
	_createPlayer: (self: Universe, userId: number) -> MockPlayer,
	_traceEvent: (self: Universe, eventType: string, details: { [string]: any }?) -> (),
	GetTrace: (self: Universe) -> { TraceEvent },
	query: (self: Universe, where: (event: TraceEvent) -> boolean) -> TraceView,
	_generateJobId: (self: Universe) -> string,
	_getPlaceConfig: (self: Universe, placeId: number) -> PlaceConfig,
	_matchmakePlayerToPlace: (self: Universe, placeId: number) -> string,
	StartServer: (self: Universe, placeId: number) -> string,
	StopServer: (self: Universe, jobId: string) -> (),
	CrashServer: (self: Universe, jobId: string) -> (),
	JoinPlayerToServer: (self: Universe, userId: number, jobId: string) -> (),
	RemovePlayerFromServer: (self: Universe, userId: number, jobId: string) -> (),
	_teleport: (self: Universe, userId: number, targetPlaceId: number) -> (),
	_finishShutdown: (self: Universe, jobId: string) -> (),
	Teleport: (self: Universe, userId: number, placeId: number) -> (),
	GetServer: (self: Universe, jobId: string) -> {},
	GetServersForPlace: (self: Universe, placeId: number) -> { string },
	JoinRandomPlayerToPlace: (self: Universe, placeId: number) -> (),
	RemoveRandomPlayer: (self: Universe) -> (),
	CrashRandomServer: (self: Universe, placeId: number) -> (),
	StopRandomServer: (self: Universe, placeId: number) -> (),
	CloseUniverse: (self: Universe) -> (),
}

type UniverseProps = {
	closed: boolean,
	seed: number,
	rng: Random,
	places: { [number]: PlaceConfig },
	playerPool: { [number]: { object: MockPlayer, currentServer: string? } },
	servers: {
		[string]: Server,
	},
	serverCounter: number,
	trace: { TraceEvent },
}

type Universe = typeof(setmetatable({} :: UniverseProps, {} :: UniverseImpl))

type Server = {
	JobId: string,
	PlaceId: number,

	players: { number },
	bindToCloseCallbacks: { BindToCloseCallback },
	shuttingDown: boolean,
	crashed: boolean,
	scriptTask: thread?,
	cleanupBeforeCrash: (() -> ())?,
	serverEnv: ServerEnv,
	events: { firePlayerAdded: ({ UserId: number }) -> (), firePlayerRemoving: ({ UserId: number }) -> () },
}

type MockPlayer = {
	UserId: number,
	Kick: () -> (),
}

type MockGame = {
	JobId: string,
	PlaceId: number,
	BindToClose: (self: any, cb: BindToCloseCallback) -> (),
	onCrash: (cb: () -> ()) -> (),
}

type MockPlayers = {
	PlayerAdded: RBXScriptSignal,
	PlayerRemoving: RBXScriptSignal,
	GetPlayers: (self: any) -> { Player },
}

type MockTeleportService = {
	Teleport: (self: any, targetPlaceId: number, userId: number) -> (),
}

type ServerEnv = {
	game: MockGame,
	Players: MockPlayers,
	TeleportService: MockTeleportService,
}

type TraceEvent = {
	time: number,
	type: string,
	details: { [string]: any },
}

type BindToCloseCallback = () -> ()
type PlayerEventCallback = ({ UserId: number }) -> ()

local function createEvent(): (RBXScriptSignal, ({ UserId: number }) -> ())
	local callbacks = {}
	local object = {
		Connect = function(_, cb: PlayerEventCallback)
			table.insert(callbacks, cb)
			return {
				Disconnect = function()
					for i, v in callbacks do
						if v == cb then
							table.remove(callbacks, i)
							break
						end
					end
				end,
			}
		end,
	}

	local function fire(player: { UserId: number })
		for _, cb in callbacks do
			task.spawn(cb, player)
		end
	end

	return (object :: any) :: RBXScriptSignal, fire
end

type PlaceConfig = {
	Script: (env: {}) -> (),
	MaxPlayers: number,
}

type UniverseConfig = {
	seed: number,
	places: { [number]: PlaceConfig },
	initialPlayers: { number }?,
}

local Universe: UniverseImpl = {} :: UniverseImpl
Universe.__index = Universe

function Universe.new(config: UniverseConfig): Universe
	local self = setmetatable({}, Universe)
	self.closed = false
	self.seed = config.seed
	self.rng = Random.new(self.seed)

	self.places = {}
	for placeId, placeData in config.places do
		self.places[placeId] = {
			Script = placeData.Script,
			MaxPlayers = placeData.MaxPlayers or 30,
		}
	end

	self.playerPool = {}
	if config.initialPlayers then
		for _, userId in config.initialPlayers do
			self.playerPool[userId] = (self :: any):_createPlayer(userId)
		end
	end

	self.servers = {}
	self.serverCounter = 0

	self.trace = {}
	self.eventCounter = 0

	return self
end

function Universe:_createPlayer(userId: number): MockPlayer
	return {
		UserId = userId,
		Kick = function()
			local jobId = self.playerPool[userId].currentServer
			if jobId then
				self:RemovePlayerFromServer(userId, jobId)
			end
		end,
	}
end

function Universe:_traceEvent(name: string, details: { [string]: any }?)
	self.eventCounter = self.eventCounter + 1
	local event = {
		id = self.eventCounter,
		time = os.clock(),
		name = name,
		type = name,
		details = details or {},
	}
	table.insert(self.trace, event)
	return event
end

function Universe:GetTrace()
	return self.trace
end

function Universe:query(predicate: (event: TraceEvent) -> boolean): TraceView
	local view = TraceView.new(self.trace)
	for i, event in self.trace do
		if predicate(event) then
			table.insert(view._resultIndices, i)
		end
	end
	return view
end

function Universe:_generateJobId(): string
	self.serverCounter += 1
	return "Server_" .. tostring(self.serverCounter)
end

function Universe:_getPlaceConfig(placeId: number)
	local place = self.places[placeId]
	if not place then
		error("Invalid placeId: " .. tostring(placeId))
	end
	return place
end

function Universe:_matchmakePlayerToPlace(placeId: number): string
	local placeConfig = self:_getPlaceConfig(placeId)

	local candidates = {}
	for jobId, server in self.servers do
		if
			server.PlaceId == placeId
			and #server.players < placeConfig.MaxPlayers
			and not server.shuttingDown
			and not server.crashed
		then
			table.insert(candidates, jobId)
		end
	end

	local chosenJobId
	if #candidates > 0 then
		chosenJobId = candidates[self.rng:NextInteger(1, #candidates)]
	else
		chosenJobId = self:StartServer(placeId)
	end

	return chosenJobId
end

function Universe:StartServer(placeId: number): string
	if self.closed then
		error("Cannot start server in closed universe.")
	end

	self:_getPlaceConfig(placeId)

	local jobId = self:_generateJobId()

	local bindToCloseCallbacks = {}

	local playerAddedEvent, firePlayerAdded = createEvent()
	local playerRemovingEvent, firePlayerRemoving = createEvent()

	local server: Server

	local PlayersService: MockPlayers = {
		PlayerAdded = playerAddedEvent,
		PlayerRemoving = playerRemovingEvent,
		GetPlayers = function()
			local users = {}
			for _, plrId in server.players do
				table.insert(users, self.playerPool[plrId].object)
			end
			return (users :: any) :: { Player }
		end,
	}

	local gameMock: MockGame = {
		JobId = jobId,
		PlaceId = placeId,
		BindToClose = function(_, cb: BindToCloseCallback)
			table.insert(bindToCloseCallbacks, cb)
		end,
		onCrash = function(cb: () -> ())
			server.cleanupBeforeCrash = cb
		end,
	}

	local TeleportServiceMock: MockTeleportService = {
		Teleport = function(_, targetPlaceId: number, userId: number)
			self:_teleport(userId, targetPlaceId)
		end,
	}

	local events = {
		firePlayerAdded = firePlayerAdded,
		firePlayerRemoving = firePlayerRemoving,
	}

	server = {
		JobId = jobId,
		PlaceId = placeId,
		players = {},
		bindToCloseCallbacks = bindToCloseCallbacks,
		shuttingDown = false,
		crashed = false,
		scriptTask = nil,
		serverEnv = {
			game = gameMock,
			Players = PlayersService,
			TeleportService = TeleportServiceMock,
		},
		events = events,
	}

	self.servers[jobId] = server

	self:_traceEvent("ServerStarted", { JobId = jobId, PlaceId = placeId })

	local placeScript = self.places[placeId].Script
	local t = task.spawn(placeScript, server.serverEnv)
	server.scriptTask = t

	return jobId
end

function Universe:StopServer(jobId: string)
	local server = self.servers[jobId]
	if not server or server.shuttingDown or server.crashed then
		return
	end
	server.shuttingDown = true
	self:_traceEvent("ServerShutdownInitiated", { JobId = jobId })

	local callbacks = server.bindToCloseCallbacks
	local doneCount = 0
	local total = #callbacks
	if total == 0 then
		self:_finishShutdown(jobId)
		return
	end

	local completed = false
	local function onCbDone()
		doneCount += 1
		if doneCount == total and not completed then
			completed = true
		end
	end

	for _, cb in callbacks do
		task.spawn(function()
			self:_traceEvent("BindToCloseStarted", { JobId = jobId })
			local ok, err = pcall(function()
				cb()
			end)
			if not ok then
				warn("Error in BindToClose callback: " .. tostring(err))
			end
			self:_traceEvent("BindToCloseCompleted", { JobId = jobId })
			onCbDone()
		end)
	end

	local start = os.clock()
	while not completed and os.clock() - start < 30 do
		task.wait(0.1)
	end

	self:_finishShutdown(jobId)
end

function Universe:_finishShutdown(jobId: string)
	local server = self.servers[jobId]
	if not server then
		return
	end

	if server.scriptTask then
		task.cancel(server.scriptTask)
	end

	for _, userId in server.players do
		self:RemovePlayerFromServer(userId, jobId)
	end

	self.servers[jobId] = nil
	self:_traceEvent("ServerStopped", { JobId = jobId })
end

function Universe:CrashServer(jobId: string)
	local server = self.servers[jobId]
	if not server or server.crashed then
		return
	end
	server.crashed = true
	self:_traceEvent("ServerCrashed", { JobId = jobId })

	if server.cleanupBeforeCrash then
		server.cleanupBeforeCrash()
	end

	if server.scriptTask then
		task.cancel(server.scriptTask)
	end

	local plrs = { unpack(server.players) }
	for _, userId in plrs do
		self:RemovePlayerFromServer(userId, jobId)
	end

	self.servers[jobId] = nil
end

function Universe:JoinPlayerToServer(userId: number, jobId: string)
	local server = self.servers[jobId]
	if not server or server.shuttingDown or server.crashed then
		error("Cannot join player to a non-running or shutting down server.")
	end
	local placeConfig = self:_getPlaceConfig(server.PlaceId)
	if #server.players >= placeConfig.MaxPlayers then
		error("Server is full.")
	end

	local playerData = self.playerPool[userId]
	if not playerData then
		self.playerPool[userId] = { object = self:_createPlayer(userId), currentServer = nil }
		playerData = self.playerPool[userId]
	end

	if playerData.currentServer and playerData.currentServer ~= jobId then
		self:RemovePlayerFromServer(userId, playerData.currentServer)
	end

	table.insert(server.players, userId)
	playerData.currentServer = jobId
	self:_traceEvent("PlayerJoined", { UserId = userId, JobId = jobId })
	server.events.firePlayerAdded(playerData.object)
end

function Universe:RemovePlayerFromServer(userId: number, jobId: string)
	local server = self.servers[jobId]
	if not server then
		return
	end

	local idx = nil
	for i, uid in server.players do
		if uid == userId then
			idx = i
			break
		end
	end

	if idx then
		table.remove(server.players, idx)
		self:_traceEvent("PlayerLeft", { UserId = userId, JobId = jobId })

		if not server.crashed then
			server.events.firePlayerRemoving(self.playerPool[userId].object)
		end

		local playerData = self.playerPool[userId]
		if playerData then
			playerData.currentServer = nil
		end

		if #server.players == 0 and not server.shuttingDown and not server.crashed then
			self:_traceEvent("ServerEmptied", { JobId = jobId })
			task.spawn(function()
				self:StopServer(jobId)
			end)
		end
	end
end

function Universe:_teleport(userId: number, targetPlaceId: number)
	local place = self.places[targetPlaceId]
	if not place then
		error("Teleport failed: Invalid placeId " .. tostring(targetPlaceId))
	end

	if self.rng:NextNumber() < 0.05 then
		error("Teleport internal error occurred")
	end

	local jobId = self:_matchmakePlayerToPlace(targetPlaceId)
	local playerData = self.playerPool[userId]
	if not playerData then
		self.playerPool[userId] = { object = self:_createPlayer(userId), currentServer = nil }
		playerData = self.playerPool[userId]
	end

	if playerData.currentServer then
		self:RemovePlayerFromServer(userId, playerData.currentServer)
	end

	self:JoinPlayerToServer(userId, jobId)
end

function Universe:Teleport(userId: number, placeId: number)
	return self:_teleport(userId, placeId)
end

function Universe:GetServer(jobId: string)
	return self.servers[jobId]
end

function Universe:GetServersForPlace(placeId: number)
	local result = {}
	for jobId, server in self.servers do
		if server.PlaceId == placeId then
			table.insert(result, jobId)
		end
	end
	return result
end

function Universe:JoinRandomPlayerToPlace(placeId: number)
	local userId = self.rng:NextInteger(1, 1000)
	local plr = self.playerPool[userId]
	if plr and plr.currentServer then
		return
	end
	self:JoinPlayerToServer(userId, self:_matchmakePlayerToPlace(placeId))
end

function Universe:RemoveRandomPlayer()
	for _ = 1, 10 do
		local plr = self.playerPool[self.rng:NextInteger(1, 1000)]
		if plr and plr.currentServer then
			self:RemovePlayerFromServer(plr.object.UserId, plr.currentServer)
			return
		end
	end
end

function Universe:CrashRandomServer(placeId: number)
	local server = self.servers[self:_matchmakePlayerToPlace(placeId)]
	if not server then
		return
	end

	self:CrashServer(server.JobId)
end

function Universe:StopRandomServer(placeId: number)
	local server = self.servers[self:_matchmakePlayerToPlace(placeId)]
	if not server then
		return
	end

	self:StopServer(server.JobId)
end

function Universe:CloseUniverse()
	for jobId in self.servers do
		self:StopServer(jobId)
	end
end

return Universe
