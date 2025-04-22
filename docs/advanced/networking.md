---
sidebar_position: 2
---

# Network Updates

When player data changes, you often need to notify clients to keep their UI in sync. Lyra provides a callback system through `changedCallbacks` to help manage these network updates.

## Understanding Change Callbacks

Change callbacks are functions that run whenever data changes, whether through updates or transactions. They receive three parameters:
- The key (player UserId as a string)
- The new data (frozen to prevent mutations)
- The previous data (if any, also frozen)

Here's a basic example:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage.Network)

local function syncWithClient(key: string, newData, oldData)
    local player = Players:GetPlayerByUserId(tonumber(key))
    if not player then return end

    if oldData == nil then
        -- First time data is loaded
        Network.PlayerData:FireClient(player, newData)
        return
    end
    
    -- Send only changed data
    local changes = {}
    if newData.coins ~= oldData.coins then
        changes.coins = newData.coins
    end
    if not Tables.deepEquals(newData.inventory, oldData.inventory) then
        changes.inventory = newData.inventory
    end
    
    -- Send changes to client
    Network.PlayerData:FireClient(player, changes)
end

local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    changedCallbacks = { syncWithClient },
})
```

:::tip
Compare old and new data to send only changed values, reducing network traffic.
:::

## Multiple Callbacks

While changedCallbacks are primarily used for networking, you can register multiple callbacks if needed. Each callback receives the same read-only data:

```lua
local store = Lyra.createPlayerStore({
    changedCallbacks = { 
        -- Keep clients in sync
        syncWithClient,
        
        -- Log changes for debugging
        function(key, newData, oldData)
            print(`Player {key} data changed`)
        end,
    },
})
```

## Data Safety

Change callbacks receive frozen copies of the data. This means the data is read-only and cannot be modified:

```lua
local function callback(key, newData, oldData)
    -- ❌ This will error - data is frozen
    newData.coins = 100
end
```

## See Also

- [Core Concepts](../core-concepts.md) for understanding data management
- [Getting Started](../getting-started.md) for basic setup
