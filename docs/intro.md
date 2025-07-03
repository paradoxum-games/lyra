---
sidebar_position: 1
---

# Introduction

:::danger Early Development
While Lyra has been tested and is used in production, it's still in early development. Transactions, while tested in controlled environments, have not yet been battle-tested in production at scale.

**Avoid using Lyra in production games where data loss would be catastrophic until it has been tested more thoroughly.**

Additionally, Lyra may occasionally output benign errors. These are being worked on and are not indicative of data loss or corruption.
:::

Lyra makes it easy to safely and robustly manage your game's player data. It's designed to handle large amounts of data, prevent common game-breaking bugs, and make it easy to update your data format without breaking existing saves.

## Features

- **Transactions** - A powerful tool to implement features like trading, while making bugs like item duplication impossible
- **Session Locking** - Prevents common bugs that lead to corruption and data loss
- **Validation** - Ensures your data is always in a consistent state
- **Auto-Sharding** - Handles large data by automatically splitting across multiple DataStore keys
- **Migrations** - Update your data format without breaking existing saves
- **Drop-in** - Import your existing data and switch over seamlessly

## Quick Example

Here's what using Lyra looks like:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = {
        coins = 0,
        inventory = {},
    },
    schema = t.strictInterface({
        coins = t.number,
        inventory = t.table,
    }),
})

-- Load data when players join
Players.PlayerAdded:Connect(function(player)
    store:loadAsync(player)
end)

-- Safe updates with validation
store:updateAsync(player, function(data)
    if data.coins < itemPrice then
        return false -- Abort if can't afford
    end
    data.coins -= itemPrice
    table.insert(data.inventory, itemId)
    return true
end)

-- Atomic trades between players
store:txAsync({player1, player2}, function(state)
    -- Either both changes happen or neither does
    state[player1].coins -= 100
    state[player2].coins += 100
    return true
end)
```

:::warning Avoid Stale Data
Always modify data through update functions. Never use data from a previous `:get()` call:
```lua
-- 🚫 Don't do this:
local oldData = store:getAsync(player)
store:updateAsync(player, function(newData)
    if not oldData.claimedDailyReward then -- This data might be stale!
        return false
    end
    newData.coins += 500
    newData.claimedDailyReward = true
    return true
end)

-- ✅ Do this instead:
store:updateAsync(player, function(data)
    if not data.claimedDailyReward then -- This data is always current
        return false
    end
    data.coins += 500
    data.claimedDailyReward = true
    return true
end)
```
:::

## Importing Existing Data

When switching to Lyra, you can bring your existing data:

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
            -- If there's an error, Lyra will kick the player and prompt them
            -- to rejoin to try again.
            error("Failed to reach data system")
        end

        if data ~= nil then
            return data -- Return existing data to import
        end
        
        return nil -- Return nil for new players to use template
    end,
})
```

## Installation

Add to your `wally.toml`:
```toml
Lyra = "paradoxum-games/lyra@0.6.0"
```

## Next Steps

- Check out [Getting Started](./getting-started.md) for a complete setup guide
- Read [Core Concepts](./core-concepts.md) to understand how Lyra works
- See the Advanced Features section for [migration guides](./advanced/migrations.md) and [state management](./advanced/state-management.md) tips
