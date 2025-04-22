<p align="center">
  <h1 align="center">Lyra</h1>
  <p align="center">
    Safe and simple player data management for Roblox
    <br />
    <a href="https://paradoxum-games.github.io/lyra/"><strong>Documentation »</strong></a>
  </p>
</p>

<div align="center">

[![Wally](https://img.shields.io/badge/Wally-Package-orange?style=for-the-badge)](https://wally.run/package/paradoxum-games/lyra)

</div>

Lyra makes it easy to safely and robustly manage your game's player data. It's designed to handle large amounts of data, prevent common game-breaking bugs, and make it easy to update your data format without breaking existing saves.

## Early Development

While Lyra has been tested and is used in production, it's still in early development. Some features, like transactions, while tested in controlled environments, have not yet been battle-tested in production at scale.

**Avoid using Lyra in production games where data loss would be catastrophic until it has been tested more thoroughly.**

## Features

- **Transactions** - A powerful tool to implement features like trading, while making bugs like item duplication impossible
- **Session Locking** - Prevents common bugs that lead to corruption and data loss
- **Validation** - Ensures your data is always in a consistent state
- **Auto-Sharding** - Handles large data by automatically splitting across multiple DataStore keys
- **Migrations** - Update your data format without breaking existing saves
- **Drop-in** - Import your existing data and switch over seamlessly

## Quick Start

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

-- Free up resources when players leave
Players.PlayerRemoving:Connect(function(player)
    store:unloadAsync(player)
end)

-- Update data
store:updateAsync(player, function(data)
    data.coins += 100
    return true
end)

-- Atomic transactions
store:txAsync({player1, player2}, function(state)
    local amount = 50
    state[player1].coins -= amount
    state[player2].coins += amount
    return true
end)
```

## Installation

Add to your `wally.toml`:
```toml
Lyra = "paradoxum-games/lyra@0.4.1"
```

Check out the [documentation](https://paradoxum-games.github.io/lyra/) for guides, examples, and API reference.
