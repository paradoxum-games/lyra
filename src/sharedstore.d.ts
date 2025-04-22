import { t } from "@rbxts/t";
import { MemoryStoreService, DataStoreService } from "./mock";
import { LogMessage } from "./log";
import { MigrationChain } from "./store";

/**
    Configuration for creating a new Store.

    @interface BaseStoreConfig
    .name string -- Name of the store
    .template T -- Template/default value for new data
    .schema (value: any) -> (boolean, string?) -- Validates data format
    .migrationSteps? { MigrationStep } -- Steps to migrate old data formats
    .importLegacyData? (key: string) -> any? -- Function to import legacy data
    .dataStoreService? DataStoreService -- Custom DataStore implementation
    .changedCallbacks? { (key: string, newData: T, oldData: T?) -> () } -- Run when data changes
    .logCallback? (logMessage: LogMessage) -> () -- Custom logging function

    Example usage:
    ```lua
    local config: BaseStoreConfig<PlayerData> = {
        name = "PlayerData",
        template = {
            coins = 0,
            items = {},
        },
        schema = function(value)
            return typeof(value.coins) == "number", "coins must be a number"
        end,
    }
    ```
 */
export interface BaseStoreConfig<Schema> {
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
    ) => void)[];
    // Optional callback for log messages
    logCallback?: (logMessage: LogMessage) => void;
    // Optional MemoryStoreService instance for mocking
    memoryStoreService?: MemoryStoreService;
    // Optional DataStoreService instance for mocking
    dataStoreService?: DataStoreService;
    // Disable reference protection
    disableReferenceProtection?: boolean;
}