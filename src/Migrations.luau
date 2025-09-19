--[=[
	@class Migrations
	@private

	Provides functionality for managing and applying data migrations.

	**Concept:** As data schemas evolve over time, older data stored
	in DataStores needs to be updated to match the new structure. This module
	allows defining a series of migration steps (`Types.MigrationStep`) that
	transform data from one version of the schema to the next.

	**Workflow:**
	1. Define migration steps using helpers like `makeAddFieldsStep` or `makeTransformStep`.
	   Each step must have a unique `name`.
	2. Provide the list of steps to the `Store` via `StoreContext`.
	3. When data is loaded (`Session:load`), the `apply` function in this module is called.
	4. `apply` compares the list of all defined steps against the `appliedMigrations`
	   list stored within the `DataStoreRecord`.
	5. It executes the `apply` function of any step that hasn't been applied yet, in the
	   order they are defined.
	6. The `apply` function of each step receives the current data and returns the transformed data.
	7. The names of successfully applied steps are added to the `appliedMigrations` list,
	   which is then saved back to the `DataStoreRecord`.

	**Idempotency:** The system ensures migrations are idempotent (applying them multiple
	times has the same effect as applying them once) by checking the `appliedMigrations` list
	before running a step.

	**Error Handling:** Each step's `apply` function is executed within a `pcall` to catch
	errors. If a step fails, the migration process stops, and the error is propagated.
]=]

local Log = require(script.Parent.Log)
local Promise = require(script.Parent.Promise)
local Tables = require(script.Parent.Tables)
local Types = require(script.Parent.Types)

--[=[
	Alias for a generic data table type used in migrations.

	@type Data { [string]: any }
	@within Migrations
	@private
]=]
type Data = { [string]: any }

--[=[
	Validates that the provided migration steps adhere to the expected structure.

	@within Migrations
	@param steps {Types.MigrationStep} -- The list of migration steps to validate.
	@error string -- Throws an error if any step is malformed.
]=]
local function validate(steps: { Types.MigrationStep })
	assert(typeof(steps) == "table", "steps must be a table")
	for _, step in steps do
		assert(typeof(step) == "table", "step must be a table")
		assert(typeof(step.name) == "string", "step.name must be a string")
		assert(typeof(step.apply) == "function", "step.apply must be a function")
	end
end

--[=[
	Helper function to create a common type of migration step: adding new fields
	with default values to existing data. Uses a deep merge strategy.

	@within Migrations
	@param name string -- The unique name for this migration step.
	@param fields Data -- A table containing the new fields and their default values.
	@return Types.MigrationStep -- A migration step object.
]=]
local function makeAddFieldsStep(name: string, fields: Data): Types.MigrationStep
	return {
		name = name,
		apply = function(data)
			-- Merges the default `fields` into the existing `data`.
			-- Existing keys in `data` are preserved unless they are tables themselves,
			-- in which case they are recursively merged.
			return Tables.mergeDeep(fields, data)
		end,
	}
end

--[=[
	Helper function to create a migration step that applies a custom transformation
	function to the data.

	@within Migrations
	@param name string -- The unique name for this migration step.
	@param transformFunc (currentValue: Data) -> Data -- The function that takes the current data and returns the transformed data.
	@return Types.MigrationStep -- A migration step object.
]=]
local function makeTransformStep(name: string, transformFunc: (currentValue: Data) -> Data): Types.MigrationStep
	return {
		name = name,
		apply = transformFunc,
	}
end

--[=[
	Parameters for the `apply` function.

	@interface ApplyParams
	@within Migrations
	.logger Log.Logger -- Logger instance for logging migration progress and errors.
	.data Data -- The current data loaded from the DataStore record's File.
	.steps {Types.MigrationStep} -- The list of all defined migration steps for the store.
	.appliedMigrations {string} -- The list of names of migration steps already applied to this specific data record, loaded from the DataStoreRecord.
]=]
export type ApplyParams = {
	logger: Log.Logger,
	data: Data,
	steps: { Types.MigrationStep },
	appliedMigrations: { string },
}

--[=[
	Result returned by the `apply` function upon successful completion.

	@interface ApplyResult
	@within Migrations
	.data Data -- The potentially modified data after applying necessary migration steps.
	.appliedMigrations {string} -- The updated list of applied migration names, including any newly applied steps. This should be saved back to the DataStoreRecord.
]=]
export type ApplyResult = {
	data: Data,
	appliedMigrations: { string },
}

--[=[
	Applies pending migration steps to the data.

	Iterates through the defined `steps` and applies any step whose name is not
	present in the `appliedMigrations` list. Ensures idempotency and uses `pcall`
	for safe execution of each step's `apply` function.

	@within Migrations
	@param params ApplyParams -- The parameters for applying migrations.
	@return Promise<ApplyResult> -- A Promise that resolves with the updated data and the new list of applied migration names.
	@error string -- Rejects if any migration step fails during `pcall`.
]=]
local function apply(params: ApplyParams): Promise.TPromise<ApplyResult>
	local logger = params.logger
	local currentData = params.data
	-- Clone the list to avoid modifying the original list passed in params directly within this function scope.
	local appliedMigrations = table.clone(params.appliedMigrations)

	-- Create a set for quick lookup of already applied migrations.
	local appliedSet = {}
	for _, name in appliedMigrations do
		appliedSet[name] = true
	end

	return Promise.new(function(resolve, reject)
		for _, step in params.steps do
			-- Idempotency Check: Only apply if the step name is not in the applied set.
			if not appliedSet[step.name] then
				logger:log("trace", "applying migration step", { stepName = step.name })

				-- Deep copy the data before applying the step to avoid modifying the original
				-- `currentData` reference in case of an error within `step.apply`.
				-- TODO: Do we actually care about atomicity here? This might be a performance hit.
				local staged = Tables.copyDeep(currentData)
				-- Safely execute the migration step's apply function.
				local ok, result = pcall(step.apply, staged)

				if not ok then
					-- If pcall failed, log the error and reject the promise.
					logger:log("error", "failed to apply migration step", { stepName = step.name, error = result })
					return reject(`Failed migration step '{step.name}': {result}`)
				end

				-- If pcall succeeded, update currentData with the result.
				-- Deep copy again to ensure `currentData` holds a distinct copy for the next step.
				-- TODO: We should probably just warn about not modifying the data after returning - this is expensive.
				currentData = Tables.copyDeep(result)
				-- Add the step name to the list of applied migrations for this record.
				table.insert(appliedMigrations, step.name)
				-- Also update the lookup set for the next iteration.
				appliedSet[step.name] = true
			end
		end

		-- All applicable steps applied successfully. Resolve with the final data and updated list.
		return resolve({
			data = currentData,
			appliedMigrations = appliedMigrations,
		})
	end)
end

--[=[
	Utility function to extract just the names from a list of migration steps.

	@within Migrations
	@param migrations {Types.MigrationStep} -- The list of migration steps.
	@return {string} -- A list containing only the names of the migration steps.
]=]
local function getStepNames(migrations: { Types.MigrationStep }): { string }
	local names = {}
	for _, step in migrations do
		table.insert(names, step.name)
	end
	return names
end

return {
	makeAddFieldsStep = makeAddFieldsStep,
	makeTransformStep = makeTransformStep,
	validate = validate,
	apply = apply,
	getStepNames = getStepNames,
}
