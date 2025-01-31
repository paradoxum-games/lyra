import { MigrationStep as TMigrationStep } from "./store";
import { PlayerStoreConfig, PlayerStore } from "./playerstore";
import { LogLevel } from "./log";

export namespace MigrationStep {
    /**
     * Adds fields to unmigrated data.
     *
     * @param name The name of the migration step (Must be unique and cannot be changed later)
     * @param fields The fields to add to the data
     */
    export function addFields<Arg, Return, NewFields extends object>(
        name: string,
        fields: NewFields
    ): TMigrationStep<Arg, Return & NewFields>;
    /**
     * Transforms the data using a function.
     *
     * @param name The name of the migration step (Must be unique and cannot be changed later)
     * @param transformer The function to transform the data
     */
    export function transform<Arg, Return>(
        name: string,
        transformer: (data: Arg) => Return
    ): TMigrationStep<Arg, Return>;
}

/**
 * Creates a player store.
 *
 * @param config The configuration for the player store.
 */
export function createPlayerStore<Schema extends object>(
    config: PlayerStoreConfig<Schema>
): PlayerStore<Schema>;

/**
 * Sets the log level for the library.
 *
 * @param level The log level to set.
 */
export function setLogLevel(level: LogLevel): void;

export type { LogLevel, LogMessage } from "./log";
export { PlayerStore } from "./playerstore";
export type { PlayerStoreConfig } from "./playerstore";
export { Store } from "./store";
export type { StoreConfig, MigrationStep as TMigrationStep } from "./store";
export {
    DataStoreService as MockDataStoreService,
    MemoryStoreService as MockMemoryStoreService,
} from "./mock";
