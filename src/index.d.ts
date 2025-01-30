import { t } from "@rbxts/t";
import { MigrationStep, PlayerStoreConfig, Store } from "./store";
import { LogLevel } from "./log";

declare namespace Lyra {
    export const MigrationStep: {
        addFields<Arg, Return, NewFields extends object>(
            name: string,
            fields: NewFields
        ): MigrationStep<Arg, Return & NewFields>;
        transform<Arg, Return>(
            name: string,
            transformer: (data: Arg) => Return
        ): MigrationStep<Arg, Return>;
    };

    export function create<Schema extends object>(
        config: PlayerStoreConfig<Schema>
    ): Store<Schema>;

    export function setLogLevel(level: LogLevel): void;
}
