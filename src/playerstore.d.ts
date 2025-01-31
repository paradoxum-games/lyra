import { t } from "@rbxts/t";
import { MemoryStoreService, DataStoreService } from "./mock";
import { LogMessage } from "./log";
import { MigrationChain } from "./store";

/**
 * Configuration for creating a new Store.

	@interface PlayerStoreConfig
	.name string -- The name of the store
	.template T -- The template data for new keys
	.schema (value: any) -> (boolean, string?) -- A function to validate data
	.migrationSteps { MigrationStep }? -- Optional migration steps
	.importLegacyData ((key: string) -> any?)? -- Optional function to import legacy data
	.changedCallbacks { (key: string, newData: T, oldData: T?) -> () -> () }? -- Optional callbacks for data changes
	.logCallback ((logMessage: LogMessage) -> ())? -- Optional callback for log messages
	.memoryStoreService MemoryStoreService? -- Optional MemoryStoreService instance for mocking
	.dataStoreService DataStoreService? -- Optional DataStoreService instance for mocking
 */
export interface PlayerStoreConfig<Schema> {
    // The name of the store
    name: string;
    // The template data for new keys
    template: NoInfer<Schema>;
    // A function to validate data
    schema: t.check<Schema>;
    // Optional migration steps
    migrationSteps?: MigrationChain<NoInfer<Schema>>;
    // Optional function to import legacy data
    importLegacyData?: (key: string) => any | undefined;
    // Optional callbacks for data changes
    changedCallbacks?: ((
        key: string,
        newData: Schema,
        oldData?: Schema
    ) => () => void)[];
    // Optional callback for log messages
    logCallback?: (logMessage: LogMessage) => void;
    // Optional MemoryStoreService instance for mocking
    memoryStoreService?: MemoryStoreService;
    // Optional DataStoreService instance for mocking
    dataStoreService?: DataStoreService;
}

export namespace PlayerStore {
    /**
     * Creates a player store.
     *
     * @param config The configuration for the player store.
     */
    export function create<Schema extends object>(
        config: PlayerStoreConfig<Schema>
    ): PlayerStore<Schema>;
}

export interface PlayerStore<Schema extends object> {
    /**
        Gets the current data for the given player.
    
        ```lua
        playerStore:get(player):andThen(function(data)
            print(player.Name, "has", data.coins, "coins")
        end)
        ```
    
        @error "Key not loaded" -- The player's data hasn't been loaded
        @error "Store is closed" -- The store has been closed
        @returns {Promise<Schema>} -- Resolves with the player's data
    */
    get(player: Player): Promise<Schema>;
    /**
     * Syntatic sugar for `get(player):expect().`
     * @returns {Schema} -- The player's data
     */
    getAsync(player: Player): Schema;
    /**
        Loads data for the given player. Must be called before using other methods.

        ```lua
        playerStore:load(player):andThen(function()
            print("Data loaded for", player.Name)
        end)
        ```

        ! If loading fails, the player will be kicked from the game.

        @error "Load already in progress" -- Another load is in progress for this player
        @error "Store is closed" -- The store has been closed
        @returns {Promise<void>} -- Resolves when data is loaded
    */
    load(player: Player): Promise<void>;
    /**
     * Syntatic sugar for `load(player):expect().`
     */
    loadAsync(player: Player): void;
    /**
     * 	Unloads data for the given player.

        ```lua
        playerStore:unload(player):andThen(function()
            print("Data unloaded for", player.Name)
        end)
        ```

        @error "Store is closed" -- The store has been closed
        @returns {Promise<boolean>} -- Resolves when the update is complete, with a boolean indicating success
     */
    unload(player: Player): Promise<boolean>;
    /**
     * Syntatic sugar for `unload(player):expect().`
     */
    unloadAsync(player: Player): boolean;
    /**
     * 	Updates data for the given player using a transform function.
        The transform function must return true to commit changes, or false to abort.

        ```lua
        playerStore:update(player, function(data)
            if data.coins < 100 then
                data.coins += 50
                return true -- Commit changes
            end
            return false -- Don't commit changes
        end)
        ```

        @error "Key not loaded" -- The player's data hasn't been loaded
        @error "Store is closed" -- The store has been closed
        @error "Schema validation failed" -- The transformed data failed schema validation
        @returns {Promise<boolean>} -- Resolves when the update is complete
     */
    update(
        player: Player,
        transformFunction: (data: Schema) => boolean
    ): Promise<boolean>;
    /**
     * Syntatic sugar for `update(player, transformFunction):expect().`
     */
    updateAsync(
        player: Player,
        transformFunction: (data: Schema) => boolean
    ): boolean;
    /**
     * 	Performs a transaction across multiple players' data atomically.
        All players' data must be loaded first. Either all changes apply or none do.

        ```lua
        playerStore:tx({player1, player2}, function(state)
            -- Transfer coins between players
            if state[player1].coins >= 100 then
                state[player1].coins -= 100
                state[player2].coins += 100
                return true -- Commit transaction
            end
            return false -- Abort transaction
        end)
        ```

        @error "Key not loaded" -- One or more players' data hasn't been loaded
        @error "Store is closed" -- The store has been closed
        @error "Schema validation failed" -- The transformed data failed schema validation
        @returns {Promise<void>} -- Resolves when the transaction is complete
     */
    tx(
        players: Player[],
        transformFunction: (state: Map<Player, Schema>) => boolean
    ): Promise<void>;
    /**
     * Syntatic sugar for `tx(players, transformFunction):expect().`
     */
    txAsync(
        players: Player[],
        transformFunction: (state: Map<Player, Schema>) => boolean
    ): void;
    /**
     * 	Forces an immediate save of the given player's data.

        ! Data is automatically saved periodically, so manual saves are usually unnecessary.

        @error "Key not loaded" -- The player's data hasn't been loaded
        @error "Store is closed" -- The store has been closed
        @returns {Promise<void>} -- Resolves when the save is complete
     */
    save(player: Player): Promise<void>;
    /**
     * Syntatic sugar for `save(player):expect().`
     */
    saveAsync(player: Player): void;
    /**
     * 	Closes the store and unloads all active sessions.
        The store cannot be used after closing.

        @returns {Promise<void>} -- Resolves when the store is closed
     */
    close(): Promise<void>;
    /**
     * Syntatic sugar for `close():expect().`
     */
    closeAsync(): void;
    /**
     * Returns the current data for the given key without loading it into the store.

        ```lua
        playerStore:peek(userId):andThen(function(data)
            print("Current coins:", data.coins)
        end)
        ```

        @returns {Promise<Schema>} -- Resolves with the current data
     */
    peek(userId: number): Promise<Schema>;
    /**
     * Syntatic sugar for `peek(userId):expect().`
     */
    peekAsync(userId: number): Schema;
}
