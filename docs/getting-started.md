---
sidebar_position: 2
---

# Getting Started

Let's get Lyra set up in your game and cover the basics of saving player data.

## Installation

Add Lyra to your `wally.toml`:

```toml
Lyra = "paradoxum-games/lyra@0.6.0"
```

:::tip
If you're new to Wally, check out the [Wally installation guide](https://wally.run/install).
:::

## Basic Setup

Here's how to set up Lyra with a simple data structure:

```lua
local Players = game:GetService("Players")
local Lyra = require(path.to.Lyra)

-- Define your data template
local template = {
    coins = 0,
    inventory = {},
}

-- Create schema to validate data
local schema = t.strictInterface({
    coins = t.number,
    inventory = t.table,
})

-- Create the store
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
})

-- Load data when players join
Players.PlayerAdded:Connect(function(player)
    store:loadAsync(player)
end)

-- Save and clean up when they leave
Players.PlayerRemoving:Connect(function(player)
    store:unloadAsync(player)
end)

-- Ensure data is saved when the game closes
game:BindToClose(function()
    store:closeAsync()
end)
```

## Working with Data

### Reading Data

You can read player data, but remember that it might change between reads:

```lua
-- ⚠️ Only use this data for reading
-- Don't save it for later use
local data = store:getAsync(player)
print(`{player.Name} has {data.coins} coins`)
```

### Modifying Data

Always modify data through update functions:

```lua
-- Simple update
store:updateAsync(player, function(data)
    data.coins += 100
    return true
end)

-- Conditional update
store:updateAsync(player, function(data)
    if data.coins < itemPrice then
        return false -- Abort the update
    end
    
    data.coins -= itemPrice
    table.insert(data.inventory, itemId)
    return true
end)
```

### Trading Between Players

Use transactions for operations involving multiple players:

```lua
store:txAsync({player1, player2}, function(state)
    -- Transfer coins
    if state[player1].coins < amount then
        return false -- Abort if not enough coins
    end
    
    state[player1].coins -= amount
    state[player2].coins += amount
    return true
end)
```

## Importing Existing Data

If you're migrating from another DataStore library, you can import your existing data:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    importLegacyData = function(key)
        local success, data = pcall(function()
            return YourCurrentSystem.getData(key)
        end)
        
        if not success then
            error("Failed to reach data system") -- Player will be kicked and can retry
        end

        if data ~= nil then
            return data -- Return existing data to import
        end
        
        return nil -- Return nil for new players to use template
    end,
})
```

## ProcessReceipt Example

Here's an example of how you would use Lyra in ProcessReceipt:

```lua
local ProductCallbacks = {
    [12345] = function(player, receiptInfo, data)
        data.coins += 100
        return true
    end,
}

local function processReceipt(receiptInfo)
    local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
    if not player then
        return Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local productCallback = ProductCallbacks[receiptInfo.ProductId]
    if not productCallback then
        return Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local ok, result = pcall(function()
        store:updateAsync(player, function(data)
            -- Assuming you have 'purchaseHistory' in your template and schema:
            if table.find(data.purchaseHistory, receiptInfo.PurchaseId) then
               return false -- Prevent duplicate purchases
            end
            table.insert(data.purchaseHistory, 1, receiptInfo.PurchaseId)
            for i = 1000, #data.purchaseHistory do
                data.purchaseHistory[i] = nil -- Remove old purchases
            end

            return productCallback(player, receiptInfo, data)
        end)
        store:saveAsync(player)
    end)
    if not ok then
        warn(`ProcessReceipt failed: {result}`)
        return Enum.ProductPurchaseDecision.NotProcessedYet
    end

    return Enum.ProductPurchaseDecision.PurchaseGranted
end
```

## Promise-based API

Lyra also offers a Promise-based API:

```lua
store:update(player, function(data)
    data.coins -= itemPrice
    data.inventory.weapon = "starter_sword"
    return true
end):andThen(function()
    print("Purchase successful!")
end):catch(function(err)
    print(`Purchase failed: {err}`)
end)
```

## Next Steps

Now that you've got the basics down, check out:

- [Core Concepts](./core-concepts.md) for a deeper understanding
- [Data Migrations](./advanced/migrations.md) for updating data structure
- [Network Updates](./advanced/networking.md) for client synchronization
- [Debugging](./advanced/debugging.md) for troubleshooting
