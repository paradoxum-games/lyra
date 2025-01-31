type MigrationChain<ValidatedData> = MigrationStep<any, any>[];

export interface MigrationStep<Argument, ReturnValue> {
    // The name of the migration step
    name: string;
    // The function to apply the migration step
    apply: (data: Argument) => ReturnValue;
}
