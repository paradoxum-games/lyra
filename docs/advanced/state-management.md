---
sidebar_position: 3
---

# State Management and Lyra

## Lyra as the Source of Truth

When building games with Lyra, it's important to understand that **Lyra is designed to be the source of truth for your data**. This design choice enables Lyra to provide strong guarantees about data consistency and integrity.

### Common Integration Patterns

Some developers use state management libraries like Reflex, Charm, or custom solutions alongside Lyra. When integrating these tools, there are two common approaches:

#### Pattern 1: External State as Source of Truth (Not Recommended)

```lua
-- External state is the primary source of truth
function giveCoins(player, amount)
    -- Update external state first
    gameState.players[player.UserId].coins += amount

	-- Then flush to Lyra as a secondary step
	store:updateAsync(player.UserId, function(data)
		data.coins = gameState.players[player.UserId].coins
		return true
	end)
end
```

#### Pattern 2: Lyra as Source of Truth (Recommended)

```lua
-- Lyra is the primary source of truth
function giveCoins(player, amount)
    -- Update Lyra first
    store:updateAsync(player.UserId, function(data)
        data.coins += amount
        return true
    end)
    
    -- Other systems can derive from Lyra through changedCallbacks
end
```

### Why Lyra Should Be the Source of Truth

When Lyra isn't the primary source of truth, several key features become compromised:

1. **Atomicity**: Lyra's updates are atomic - they either succeed completely or fail entirely. This guarantee is lost when changes originate elsewhere.

2. **Transactions**: Lyra's transactions allow updating multiple players' data atomically - a feature that requires Lyra to control the data flow.

3. **Data Consistency**: When external state and Lyra diverge (e.g., if a Lyra update fails), reconciling the differences becomes complex.

4. **Schema Validation**: Lyra validates data against your schema during updates, catching issues early. When changes happen outside Lyra, these validations are bypassed, leading to potential data corruption.

### The Technical Reason

Behind the scenes, Lyra maintains data integrity through a carefully orchestrated system:

- Updates and transactions are queued and processed in sequence
- Transactions require waiting for some DataStore calls to guarantee atomicity
- During a transaction, updates to affected keys are paused until the transaction completes
- This is necessary because changes from transactions are only considered valid if all DataStore operations succeed
- If any operation fails, Lyra discards all pending changes to maintain consistency

If external systems modify data at the same time Lyra is processing a transaction, this careful balance breaks down. The only way to handle such conflicts would require complex rollback mechanisms that impose significant constraints on your code structure.

By making Lyra the source of truth, you get robust data integrity without these complications.

## Practical Integration Strategies

If you're using a state management library alongside Lyra, consider these approaches:

### For Game Systems and Services

Use your state management library for ephemeral game state, while letting Lyra handle persistent player data:

```lua
-- Lyra handles persistent data
store:updateAsync(player.UserId, function(data)
    data.questProgress.questId = 5
    data.questProgress.stepsCompleted += 1
    return true
end)

-- Game systems can track active state separately
gameState.activeQuests[player.UserId] = {
    questId = 5,
    timeRemaining = 600,
    location = workspace.QuestLocations.Cave
}
```

### Deriving State from Lyra

Let Lyra drive updates to the rest of your code through callbacks:

```lua
-- When Lyra data changes, update external state
changedCallbacks = {
    function(key, newData, oldData)
        local playerId = tonumber(key)
		gameState.players[playerId][key] = newData[key]
    end
}
```

## Common Questions

### "How do I handle complex state that isn't just player data?"

Lyra is primarily designed for persistent player data. For state that doesn't need persistence, it's fine to use other state management approaches:

```lua
-- State that doesn't need persistence
local gameState = {
    currentRound = 1,
    roundStartTime = os.time(),
    activePlayers = {},
}

-- Player data that needs persistence uses Lyra
function playerCompletedRound(player)
	local score = gameState.roundScores[player.UserId] or 0
    store:updateAsync(player.UserId, function(data)
        data.roundsCompleted += 1
        data.totalScore += score
        return true
    end)
end
```

### "What about systems that need to react to data changes?"

You can use Lyra's changedCallbacks to notify other systems when data changes:

```lua
-- Set up a badge award system that reacts to data changes
changedCallbacks = {
    function(key, newData, oldData)
		if oldData == nil then return end
        local playerId = tonumber(key)
        
        -- Check if player reached a milestone
        if oldData.coins < 1000 and newData.coins >= 1000 {
            BadgeService.awardBadge(playerId, BADGES.COIN_COLLECTOR)
        }
        
        -- Check if player completed all quests
        if #oldData.completedQuests < 10 and #newData.completedQuests >= 10 {
            BadgeService.awardBadge(playerId, BADGES.QUEST_MASTER)
        }
    end
}
```

## Recap

While it might be tempting to use another state management system as your primary source of truth, doing so limits Lyra's ability to provide its core benefits. By keeping Lyra as the source of truth for persistent data, you'll build more robust games with fewer data-related issues.
