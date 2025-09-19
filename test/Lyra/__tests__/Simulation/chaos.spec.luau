local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local MockMemoryStoreService = require(ReplicatedStorage.Packages.Lyra.MockMemoryStoreService)
local Universe = require(script.Parent.Parent.Universe)
local PlayerStore = require(ReplicatedStorage.Packages.Lyra.PlayerStore)
local Tables = require(ReplicatedStorage.Packages.Lyra.Tables)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local jest = JestGlobals.jest

local TestConfig = {
	Seeds = { 1, 2, 3 },
	Durations = { 60 * 60 * 2, 60 * 60 * 4, 60 * 60 * 6 },
	MaxPlayers = 20,
	OperationInterval = 15,

	PlayerActivity = {
		JoinChance = 0.1,
		LeaveChance = 0.01,
		ServerStopChance = 0.005,
		ServerCrashChance = 0.001,
	},

	Template = {
		coins = 0,
		inventory = {},
	},
}

local PlayerData = {
	new = function()
		return {
			canonData = {},
			stagedData = {},
			failures = {},
			dataLossEvents = {},
			lastServerCrashTime = 0,

			commitStagedData = function(self, player)
				if self.stagedData[player.UserId] then
					self.canonData[player.UserId] = Tables.copyDeep(self.stagedData[player.UserId])
				end
			end,

			verifyPlayerData = function(self, player, store)
				local ok, data = store:get(player):await()
				if not ok or not data or not self.canonData[player.UserId] then
					return
				end

				if not Tables.equalsDeep(data, self.canonData[player.UserId]) then
					table.insert(self.failures, {
						time = os.clock(),
						error = string.format(
							"Data mismatch for player %s: expected %s, got %s",
							player.UserId,
							HttpService:JSONEncode(self.canonData[player.UserId]),
							HttpService:JSONEncode(data)
						),
					})
				end
			end,

			handleDataLoss = function(self, player)
				if
					self.stagedData[player.UserId] ~= nil
					and not Tables.equalsDeep(self.stagedData[player.UserId], self.canonData[player.UserId])
				then
					table.insert(self.dataLossEvents, {
						time = os.clock(),
						player = player.UserId,
						expected = self.canonData[player.UserId],
						actual = self.stagedData[player.UserId],
						timeSinceCrash = os.clock() - self.lastServerCrashTime,
					})
					self.stagedData[player.UserId] = Tables.copyDeep(self.canonData[player.UserId])
					return true
				else
					self.stagedData[player.UserId] = Tables.copyDeep(self.canonData[player.UserId])
					return false
				end
			end,

			initializePlayer = function(self, player)
				if self.canonData[player.UserId] == nil then
					self.canonData[player.UserId] = Tables.copyDeep(TestConfig.Template)
				end
			end,
		}
	end,
}

local Operations = {
	{
		name = "addCoins",
		weight = 1,
		execute = function(store, player, playerData, rand, universe)
			local coinsToAdd = rand:NextInteger(1, 100)
			universe:_traceEvent("DataOperation", {
				type = "addCoins",
				player = player.UserId,
				UserId = player.UserId,
				amount = coinsToAdd,
				before = playerData.stagedData[player.UserId] and playerData.stagedData[player.UserId].coins,
			})
			store
				:update(player, function(data)
					data.coins += coinsToAdd
					return true
				end)
				:tap(function()
					if playerData.canonData[player.UserId] then
						playerData.stagedData[player.UserId].coins += coinsToAdd
						universe:_traceEvent("DataOperationComplete", {
							type = "addCoins",
							player = player.UserId,
							UserId = player.UserId,
							after = playerData.stagedData[player.UserId].coins,
						})
					end
				end)
				:await()
		end,
	},
	{
		name = "removeCoins",
		weight = 1,
		execute = function(store, player, playerData, rand, universe)
			local coinsToRemove = rand:NextInteger(1, 50)
			universe:_traceEvent("DataOperation", {
				type = "removeCoins",
				player = player.UserId,
				UserId = player.UserId,
				amount = coinsToRemove,
				before = playerData.stagedData[player.UserId] and playerData.stagedData[player.UserId].coins,
			})
			store
				:update(player, function(data)
					data.coins = math.max(0, data.coins - coinsToRemove)
					return true
				end)
				:tap(function()
					if playerData.canonData[player.UserId] then
						playerData.stagedData[player.UserId].coins =
							math.max(0, playerData.stagedData[player.UserId].coins - coinsToRemove)
						universe:_traceEvent("DataOperationComplete", {
							type = "removeCoins",
							player = player.UserId,
							UserId = player.UserId,
							after = playerData.stagedData[player.UserId].coins,
						})
					end
				end)
				:await()
		end,
	},
	{
		name = "addItem",
		weight = 1,
		execute = function(store, player, playerData, rand, universe)
			local itemId = tostring(rand:NextInteger(1, 100))
			universe:_traceEvent("DataOperation", {
				type = "addItem",
				player = player.UserId,
				UserId = player.UserId,
				itemId = itemId,
			})
			store
				:update(player, function(data)
					data.inventory[itemId] = true
					return true
				end)
				:tap(function()
					if playerData.canonData[player.UserId] then
						playerData.stagedData[player.UserId].inventory[itemId] = true
						universe:_traceEvent("DataOperationComplete", {
							type = "addItem",
							player = player.UserId,
							UserId = player.UserId,
							itemId = itemId,
						})
					end
				end)
				:await()
		end,
	},
	{
		name = "getData",
		weight = 1,
		execute = function(store, player, _, _, universe)
			universe:_traceEvent("DataOperation", {
				type = "getData",
				player = player.UserId,
				UserId = player.UserId,
			})
			store
				:get(player)
				:tap(function(data)
					universe:_traceEvent("DataOperationComplete", {
						type = "getData",
						player = player.UserId,
						UserId = player.UserId,
						data = data,
					})
				end)
				:await()
		end,
	},
	{
		name = "saveData",
		weight = 1,
		execute = function(store, player, playerData, _, universe)
			universe:_traceEvent("DataOperation", {
				type = "saveData",
				player = player.UserId,
				UserId = player.UserId,
				data = playerData.stagedData[player.UserId],
			})
			store
				:save(player)
				:tap(function()
					playerData:commitStagedData(player)
					universe:_traceEvent("DataOperationComplete", {
						type = "saveData",
						player = player.UserId,
						UserId = player.UserId,
					})
				end)
				:await()
		end,
	},
	{
		name = "tradePlayers",
		weight = 1,
		execute = function(store, player, playerData, rand, universe, Players)
			if store._store._sessions[tostring(player.UserId)] == nil then
				return
			end
			local players = Players:GetPlayers()
			if #players < 2 then
				return
			end

			local otherPlayers = table.clone(players)
			table.remove(otherPlayers, table.find(otherPlayers, player))
			local otherPlayer = otherPlayers[rand:NextInteger(1, #otherPlayers)]
			if store._store._sessions[tostring(otherPlayer.UserId)] == nil then
				return
			end

			universe:_traceEvent("DataOperation", {
				type = "tradePlayers",
				player1 = player.UserId,
				player2 = otherPlayer.UserId,
				player1_coins = playerData.stagedData[player.UserId] and playerData.stagedData[player.UserId].coins,
				player2_coins = playerData.stagedData[otherPlayer.UserId]
					and playerData.stagedData[otherPlayer.UserId].coins,
			})

			store
				:tx({ player, otherPlayer }, function(state)
					state[player].coins, state[otherPlayer].coins = state[otherPlayer].coins, state[player].coins
					return true
				end)
				:tap(function()
					playerData:commitStagedData(player)
					if playerData.canonData[player.UserId] and playerData.canonData[otherPlayer.UserId] then
						playerData.stagedData[player.UserId].coins, playerData.stagedData[otherPlayer.UserId].coins =
							playerData.stagedData[otherPlayer.UserId].coins, playerData.stagedData[player.UserId].coins

						universe:_traceEvent("DataOperationComplete", {
							type = "tradePlayers",
							player1 = player.UserId,
							player2 = otherPlayer.UserId,
							player1_coins = playerData.stagedData[player.UserId].coins,
							player2_coins = playerData.stagedData[otherPlayer.UserId].coins,
						})
					end
				end)
				:await()
		end,
	},
}

beforeEach(function()
	jest.useFakeTimers()
end)

afterEach(function()
	jest.clearAllTimers()
	jest.useRealTimers()
end)

describe("PlayerStore chaos test", function()
	local testData = {}
	for _, seed in TestConfig.Seeds do
		for _, duration in TestConfig.Durations do
			table.insert(testData, { seed = seed, duration = duration })
		end
	end

	it.each(testData)("runs a long-term chaos test with seed $seed for $duration secs", function(params)
		local numIterations = 0
		local playerData = PlayerData.new()
		local serverRandCount = 0
		local universe

		local function onRejection(err)
			if
				string.find(err, "Load was cancelled")
				or string.find(err, "Load already in progress")
				or string.find(err, "Key not loaded")
				or string.find(err, "Store is closed")
				or string.find(err, "Transaction transform function returned false")
			then
				return
			end
			table.insert(playerData.failures, {
				time = os.clock(),
				error = tostring(err),
			})
		end

		local mockData = MockDataStoreService.new()
		local mockMemory = MockMemoryStoreService.new()

		local serverScript = function(env)
			local Players = env.Players
			local game = env.game

			serverRandCount += 1
			local serverRand = Random.new(params.seed + serverRandCount)

			local store = PlayerStore.createPlayerStore({
				name = "PlayerData",
				template = Tables.copyDeep(TestConfig.Template),
				dataStoreService = mockData,
				memoryStoreService = mockMemory,
				schema = function(data)
					return typeof(data.coins) == "number" and typeof(data.inventory) == "table", "Invalid data format"
				end,
				logCallback = function(logMessage)
					if logMessage.level == "error" or logMessage.level == "fatal" then
						onRejection(logMessage.message)
					end
				end,
			})

			game.onCrash(function()
				local snap = MockDataStoreService.snapshot(mockData)
				store:close()
				jest.advanceTimersByTime(1000)
				MockDataStoreService.restore(mockData, snap)
			end)

			local function executeRandomOperation(player)
				local totalWeight = 0
				for _, op in Operations do
					totalWeight += op.weight
				end

				local targetWeight = serverRand:NextNumber() * totalWeight
				local currentWeight = 0

				for _, op in Operations do
					currentWeight += op.weight
					if targetWeight <= currentWeight then
						op.execute(store, player, playerData, serverRand, universe, Players)
						break
					end
				end
			end

			Players.PlayerAdded:Connect(function(player)
				local success = store:load(player):catch(onRejection):await()
				if success then
					playerData:initializePlayer(player)
					local hadDataLoss = playerData:handleDataLoss(player)
					if not hadDataLoss then
						playerData:verifyPlayerData(player, store)
					end
				end
			end)

			Players.PlayerRemoving:Connect(function(player)
				store
					:unload(player)
					:tap(function()
						playerData:commitStagedData(player)
						playerData.stagedData[player.UserId] = nil
					end)
					:catch(onRejection)
			end)

			game:BindToClose(function()
				store:close():catch(onRejection):expect()
			end)

			while true do
				local players = Players:GetPlayers()
				if #players > 0 then
					local randomPlayer = players[serverRand:NextInteger(1, #players)]
					executeRandomOperation(randomPlayer)
				end
				task.wait(TestConfig.OperationInterval)
				numIterations += 1
			end
		end

		universe = Universe.new({
			seed = params.seed,
			places = {
				[1] = { Script = serverScript, MaxPlayers = TestConfig.MaxPlayers },
			},
		})

		local rand = Random.new(params.seed)
		local function simulatePlayerActivity()
			if rand:NextNumber() < TestConfig.PlayerActivity.JoinChance then
				universe:JoinRandomPlayerToPlace(1)
			end
			if rand:NextNumber() < TestConfig.PlayerActivity.LeaveChance then
				universe:RemoveRandomPlayer()
			end
			if rand:NextNumber() < TestConfig.PlayerActivity.ServerStopChance then
				universe:StopRandomServer(1)
			end
			if rand:NextNumber() < TestConfig.PlayerActivity.ServerCrashChance then
				universe:CrashRandomServer(1)
				playerData.lastServerCrashTime = os.clock()
			end
		end

		local startTime = os.clock()
		local t = 0
		while os.clock() - startTime < params.duration and #playerData.failures == 0 do
			task.spawn(simulatePlayerActivity)
			jest.advanceTimersByTime(TestConfig.OperationInterval * 1000)
			t += 1
			if t % 1000 == 0 then
				RunService.Heartbeat:Wait()
			end
		end

		jest.clearAllTimers()

		if #playerData.failures > 0 then
			for _, failure in playerData.failures do
				print(string.format("[%.2f] %s", failure.time, failure.error))
			end
		end

		if #playerData.dataLossEvents > 0 then
			print("\nData loss events from server crashes:")
			for _, event in playerData.dataLossEvents do
				print(
					string.format(
						"[%.2f] Player %s lost data %.2f seconds after crash. Expected: %s, Got: %s",
						event.time,
						event.player,
						event.timeSinceCrash,
						HttpService:JSONEncode(event.expected),
						HttpService:JSONEncode(event.actual)
					)
				)
			end
		end

		expect(#playerData.failures).toBe(0)
	end, 20_000)
end)
