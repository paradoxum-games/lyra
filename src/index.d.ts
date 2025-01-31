import { MigrationStep } from "./store";
import { PlayerStoreConfig, PlayerStore } from "./playerstore";
import { LogLevel } from "./log";

declare namespace Lyra {
    export const MigrationStep: {
        /**
         * Adds fields to unmigrated data.
         *
         * @param name The name of the migration step (Must be unique and cannot be changed later)
         * @param fields The fields to add to the data
         */
        addFields<Arg, Return, NewFields extends object>(
            name: string,
            fields: NewFields
        ): MigrationStep<Arg, Return & NewFields>;
        /**
         * Transforms the data using a function.
         *
         * @param name The name of the migration step (Must be unique and cannot be changed later)
         * @param transformer The function to transform the data
         */
        transform<Arg, Return>(
            name: string,
            transformer: (data: Arg) => Return
        ): MigrationStep<Arg, Return>;
    };

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
}
