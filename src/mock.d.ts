export class DataStoreService {
    constructor();
    GetDataStore(
        this: DataStoreService,
        name: string,
        scope?: string,
        options?: DataStoreOptions
    ): DataStore;
    GetGlobalDataStore(this: DataStoreService): DataStore;
    GetOrderedDataStore(
        this: DataStoreService,
        name: string,
        scope?: string
    ): OrderedDataStore;
    GetRequestBudgetForRequestType(
        this: DataStoreService,
        requestType: CastsToEnum<Enum.DataStoreRequestType>
    ): number;
    ListDataStoresAsync(
        this: DataStoreService,
        prefix?: string,
        pageSize?: number,
        cursor?: string
    ): DataStoreListingPages;
}

export class MemoryStoreService {
    constructor();
    GetHashMap(this: MemoryStoreService, name: string): MemoryStoreHashMap;
    GetQueue(
        this: MemoryStoreService,
        name: string,
        invisibilityTimeout?: number
    ): MemoryStoreQueue;
    GetSortedMap(this: MemoryStoreService, name: string): MemoryStoreSortedMap;
}
