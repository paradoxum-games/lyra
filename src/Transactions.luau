--[=[
	@class Transactions
	@private

	Provides functionality for reading data that might be involved in an ongoing,
	uncommitted transaction initiated by `Store:tx()`.

	:::note
	This module only contains the implementation for [Transactions.readTx]. Writing transactions is handled in [Store:tx]
	:::

	**Purpose:** When a `Store:tx()` operation begins, it might involve multiple steps
	(e.g., reading current data, applying changes, writing back). If a server crashes
	*before* the transaction is fully committed or rolled back, this module helps
	determine the correct state to return.

	It checks the status of the transaction ID (`txId`) stored separately in the DataStore.
	If the transaction is still pending (represented as `false`) or has failed, it returns the last known
	*committed* data. If the transaction has successfully committed (represented as `nil`), it applies the
	transaction's patch (`txPatch`) to the previously committed data (`committedData`)
	to return the *newly* committed state.

	This ensures that readers either get the stable state before the transaction or the
	final state after a successful transaction, avoiding inconsistent intermediate states.
]=]

local JsonPatch = require(script.Parent.JsonPatch)
local Types = require(script.Parent.Types)
local Promise = require(script.Parent.Promise)
local dataStoreRetry = require(script.Parent.dataStoreRetry)

--[=[
	Parameters required for the `readTx` function.

	@interface ReadTxParams
	@within Transactions
	.store DataStore -- The DataStore instance where transaction status markers are stored.
	.txInfo Types.TxInfo -- The transaction information associated with the data being read.
]=]
export type ReadTxParams = {
	store: DataStore,
	txInfo: Types.TxInfo,
}

-- We never want to read a cached value for a transaction marker.
local getOptions = Instance.new("DataStoreGetOptions")
getOptions.UseCache = false

--[=[
	Reads data, considering the status of an associated transaction.

	Checks the status of the transaction ID (`txInfo.txId`) in the DataStore.
	- If `txId` is nil (meaning no transaction was associated or it was cleaned up),
	  returns the `committedData` directly.
	- If `txId` exists:
		- Fetches the status from the DataStore using the `txId` as the key.
		- **Status Convention:**
			- `nil`: The transaction successfully committed. The corresponding `txPatch`
			  should be applied to `committedData`.
			- `false`: The transaction is still in progress or failed/rolled back. The
			  `committedData` (state before the transaction) should be returned.
		- Applies the patch if the status is `nil` and a patch exists.
		- Returns `committedData` if the status is `false`.

	Using `nil` to indicate a successful transaction allows for easier cleanup of
	transaction markers in the DataStore. Instead of setting the marker to `true`
	and only removing it after the `txId` is no longer needed, we can simply delete
	the marker immediately after a successful transaction.

	@within Transactions
	@param params ReadTxParams -- The parameters for the read operation.
	@return Promise<any> -- A Promise that resolves with the appropriate data (either committed or patched).
	@error string -- Rejects if the transaction status indicates commitment (`nil`) but the `txPatch` is missing, or if DataStore operations fail (via `dataStoreRetry`). Propagates errors from `DataStore:GetAsync` via `dataStoreRetry`.
]=]
local function readTx(params: ReadTxParams): Promise.TPromise<any>
	local txInfo = params.txInfo

	-- If there's no transaction ID, the data is simply the last committed state.
	local txId = txInfo.txId
	if txId == nil then
		return Promise.resolve(txInfo.committedData)
	end

	-- Fetch the transaction status marker from the DataStore using the txId.
	return dataStoreRetry(function()
		return params.store:GetAsync(txId, getOptions)
	end):andThen(function(txStatus)
		-- Check the transaction status using the nil/false convention.
		-- `nil` means the transaction successfully committed.
		-- `false` means it's pending or failed (rolled back).
		-- This convention avoids the need to set the marker to `true` after a
		-- successful transaction, allowing for immediate cleanup of the marker.
		if txStatus == nil then
			-- Transaction committed successfully. Apply the patch.
			if txInfo.txPatch == nil then
				-- This indicates an inconsistent state - committed but no changes recorded.
				return Promise.reject(`Transaction '{txId}' is committed but has no patch`)
			end
			-- Apply the patch to the data that was committed *before* this transaction.
			return JsonPatch.applyPatch(txInfo.committedData, txInfo.txPatch)
		else
			-- Transaction is pending or failed. Return the data as it was *before* this transaction.
			return txInfo.committedData
		end
	end)
end

return {
	readTx = readTx,
}
