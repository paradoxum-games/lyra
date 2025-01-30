import { t } from "@rbxts/t";
import { UnvalidatedData } from "./utils";
import { LogMessage } from "./log";

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

type MigrationChain<ValidatedData> =
    // Multiple migration steps
    | [
          MigrationStep<ValidatedData, any>,
          ...MigrationStep<any, any>[],
          MigrationStep<any, ValidatedData>,
      ]
    // Single migration step
    | [MigrationStep<ValidatedData, ValidatedData>]
    // No migration steps
    | [];

export interface MigrationStep<Argument, ReturnValue> {
    // The name of the migration step
    name: string;
    // The function to apply the migration step
    apply: (data: Argument) => ReturnValue;
}

export interface Store<Schema extends object> {}
