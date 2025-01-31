--!strict

local Log = require(script.Log)
local Migrations = require(script.Migrations)
local Store = require(script.Store)
local PlayerStore = require(script.PlayerStore)
local MockDataStoreService = require(script.MockDataStoreService)
local MockMemoryStoreService = require(script.MockMemoryStoreService)

return {
	MigrationStep = {
		addFields = Migrations.makeAddFieldsStep,
		transform = Migrations.makeTransformStep,
	},
	createPlayerStore = PlayerStore.createPlayerStore,
	setLogLevel = Log.setLevel,
	Store = Store,
	PlayerStore = PlayerStore,
	MockDataStoreService = MockDataStoreService,
	MockMemoryStoreService = MockMemoryStoreService,
}
