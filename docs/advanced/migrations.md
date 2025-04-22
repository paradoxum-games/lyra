---
sidebar_position: 1
---

# Data Migrations

As your game evolves, you'll need to update your data format - adding new fields, renaming existing ones, or restructuring data entirely. Lyra's migration system helps you transform existing player data safely and automatically.

:::danger Never Change Published Migrations
Once your game is live, never:
- Change the content of existing migrations
- Reorder existing migrations
- Remove existing migrations

Lyra tracks which migrations have run for each player. Changing existing migrations means some players will run different versions of the same migration, corrupting their data. Always add new migrations instead of modifying existing ones.
:::

## How Migrations Work

When a player's data is loaded, Lyra:
1. Checks which migrations have already run for this player
2. Runs any new migrations in order
3. Records which migrations were applied
4. Validates the final data against your schema

This means each migration runs exactly once per player, even if they join multiple times or on different servers.

:::info Migration Order
Migrations always run in the order they're defined. Once published, this order is permanent and should never be changed. In the snippet below, `addLevel` will always run after `addSettings`.
:::

## Adding New Fields

When adding new fields to your data, follow these steps:

1. Add the field to your template with its default value
2. Add the field to your schema to define its type/validation
3. Create a migration step using `addFields` to add it to existing data

For example:
```lua
-- Step 1: Add to template
local template = {
    coins = 0,  -- Existing field
    gems = 0,   -- New field
}

-- Step 2: Add to schema
local schema = {
    coins = t.number,
    gems = t.number,  -- New field
}

-- Step 3: Add migration
local store = Lyra.createPlayerStore({
    template = template,
    schema = schema,
    migrationSteps = {
        Lyra.MigrationStep.addFields("addGems", {
            gems = 0,
        }),
    },
})
```

## Basic Migrations

The simplest migration is adding new fields:

```lua
local store = Lyra.createPlayerStore({
    name = "PlayerData",
    template = template,
    schema = schema,
    migrationSteps = {
        Lyra.MigrationStep.addFields("addSettings", {
            settings = {
                music = true,
                sfx = true,
            }
        }),
        Lyra.MigrationStep.addFields("addLevel", {
            level = 1,
        }),
    },
})
```

:::danger Migration Names Are Permanent
Migration names (like "addSettings") are permanent and help Lyra track which migrations have run. Choose descriptive names that indicate what the migration does, as you can't change them later.
:::

## Transform Steps

For more complex changes, use `transform` steps:

```lua
migrationSteps = {
    Lyra.MigrationStep.transform("inventoryToItems", function(data)
        -- Convert simple inventory list to detailed items
        data.items = {}
        for _, item in data.inventory do
            table.insert(data.items, {
                id = item,
                acquired = os.time(),
            })
        end
        data.inventory = nil
        return data
    end),
}
```

## Migration Return Values

Each migration step must return data that will eventually match your schema after all migrations run. This means:

- Intermediate migrations can return data in any format
- The final state after all migrations must match your schema
- Lyra validates the final data against your schema after all migrations complete

For example, this is valid even though the intermediate state doesn't match the final schema:
```lua
migrationSteps = {
    -- First migration returns data that doesn't match final schema
    Lyra.MigrationStep.transform("step1", function(data)
        return {
            temporaryField = data.oldField,
        }
    }),
    
    -- Second migration transforms it to match schema
    Lyra.MigrationStep.transform("step2", function(data)
        return {
            newField = data.temporaryField,
        }
    }),
}
```

## Multiple Steps

You can chain multiple migration steps. They'll run in the order they're defined, from top to bottom:

```lua
migrationSteps = {
    -- Add new currency
    Lyra.MigrationStep.addFields("addGems", {
        gems = 0,
    }),
    -- Restructure inventory
    Lyra.MigrationStep.transform("inventoryV2", function(data)
        data.inventory = {
            items = data.inventory,
            maxSlots = 20,
        }
        return data
    end),
}
```

:::danger Migration Order Is Critical
Migrations always run in the order they're defined. This order becomes permanent once published - you can't change it later. If a new migration needs data from an older one, add it after the existing migrations.
:::

## Best Practices

When working with migrations:

1. **Plan carefully** - Once published, migrations can't be changed
2. **Keep migrations simple** - One logical change per step
3. **Test thoroughly** - Migrations run once and can't be undone

## See Also

- [Getting Started](../getting-started.md) for basic Lyra usage
- [Debugging](./debugging.md) for troubleshooting migrations
- [Core Concepts](../core-concepts.md) for understanding how Lyra works
