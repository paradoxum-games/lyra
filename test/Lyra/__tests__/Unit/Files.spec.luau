local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Files = require(ReplicatedStorage.Packages.Lyra.Files)
local MockDataStoreService = require(ReplicatedStorage.Packages.Lyra.MockDataStoreService)
local dataStoreRetry = require(ReplicatedStorage.Packages.Lyra.dataStoreRetry)
local Promise = require(ReplicatedStorage.Packages.Promise)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it
local beforeEach = JestGlobals.beforeEach
local beforeAll = JestGlobals.beforeAll
local jest = JestGlobals.jest

describe("Files", function()
	local mockData
	local store

	beforeAll(function()
		jest.useFakeTimers()
	end)

	beforeEach(function()
		mockData = MockDataStoreService.new()
		store = mockData:GetDataStore("files test")
	end)

	describe("isLargeFile", function()
		it("should return true for files with a shard property", function()
			expect(Files.isLargeFile({ shard = "shardId", count = 1 })).toBe(true)
		end)

		it("should return false for files without a shard property", function()
			expect(Files.isLargeFile({ data = "testData" } :: any)).toBe(false)
		end)

		it("should return false for empty files", function()
			expect(Files.isLargeFile({} :: any)).toBe(false)
		end)
	end)

	describe("write", function()
		local maxShardSize = 1000

		it("should correctly write small files without sharding", function()
			local promise = Files.write({
				store = store,
				data = { test = "data" },
				maxShardSize = maxShardSize,
				key = "testKey",
			}):andThen(function(file)
				expect(file.data).toEqual({ test = "data" })
				expect(file.shard).toBeNil()
				expect(file.count).toBeNil()
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should correctly handle data size equal to maxShardSize", function()
			local data = string.rep("a", maxShardSize - 2)
			local promise = Files.write({
				store = store,
				data = data,
				maxShardSize = maxShardSize,
				key = "testKey",
			}):andThen(function(file)
				expect(file.data).toEqual(data)
				expect(file.shard).toBeNil()
				expect(file.count).toBeNil()
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should correctly handle empty data inputs", function()
			local promise = Files.write({
				store = store,
				data = {},
				maxShardSize = maxShardSize,
				key = "testKey",
			}):andThen(function(file)
				expect(file.data).toEqual({})
				expect(file.shard).toBeNil()
				expect(file.count).toBeNil()
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should correctly shard and write large files", function()
			local data = {
				foo = "bar",
				baz = { 1, 2, 3 },
				large = string.rep("a", maxShardSize * 4),
			}

			local promise = Files.write({
				store = store,
				data = data,
				maxShardSize = 40,
				key = "testKey",
			}):andThen(function(file)
				expect(file.shard).never.toBeNil()
				expect(file.count).toBe(3)

				local promises = {}
				for i = 1, file.count do
					table.insert(
						promises,
						dataStoreRetry(function()
							return store:GetAsync(`{file.shard}-{i}`)
						end)
					)
				end

				return Promise.all(promises):andThen(function(shards)
					local encodedBuffer = table.concat(shards)
					local decodedBuffer = HttpService:JSONDecode(encodedBuffer)
					expect(typeof(decodedBuffer)).toBe("buffer")
					local decodedData = HttpService:JSONDecode(buffer.tostring(decodedBuffer))
					expect(decodedData).toEqual(data)
				end)
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should handle errors during shard writing", function()
			local data = string.rep("a", 10)
			local errorMessage = "Shard write error"

			MockDataStoreService.queueError(mockData, "SetAsync", errorMessage)

			local promise = Files.write({
				store = store,
				data = data,
				maxShardSize = 6,
				key = "testKey",
			})
			local e = expect(promise).rejects.toEqual({
				error = `Failed to write file: {errorMessage}`,
				file = {
					shard = expect.any("string"),
					count = 9,
				},
			})
			jest.runAllTimers()
			return e
		end)

		it("should correctly pass userIds to datastore", function()
			local data = { test = "data" }
			local userIds = { 123, 456 }
			local setCallCount = 0

			local mockSet = MockDataStoreService.mockStoreMethod(mockData, "SetAsync", jest)
			mockSet.mockImplementation(function(_self, _key, value, ids)
				setCallCount += 1
				expect(ids).toEqual(userIds)
				return Promise.resolve(value)
			end)

			local promise = Files.write({
				store = store,
				data = data,
				maxShardSize = 10,
				key = "testKey",
				userIds = userIds,
			}):andThen(function()
				expect(setCallCount).toBeGreaterThan(1)
			end)
			jest.runAllTimers()
			return promise
		end)
	end)

	describe("read", function()
		it("should correctly read small files without sharding", function()
			local data = { test = "data" }
			local file = { data = data }

			local promise = Files.read({
				store = store,
				file = file :: any,
			}):andThen(function(readData)
				expect(readData).toEqual(data)
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should correctly read and reassemble large files from shards", function()
			local data = { data = string.rep("a", 1100) }

			local promise = Files.write({
				store = store,
				data = data,
				maxShardSize = 1000,
				key = "testKey",
			}):andThen(function(file)
				return Files.read({
					store = store,
					file = file,
				}):andThen(function(readData)
					expect(readData).toEqual(data)
				end)
			end)
			jest.runAllTimers()
			return promise
		end)

		it("should handle network failures during shard reading", function()
			local file = { shard = "testShard", count = 2 }
			local errorMessage = "Network error"
			local getCallCount = 0

			local mockGet = MockDataStoreService.mockStoreMethod(mockData, "GetAsync", jest)
			mockGet.mockImplementation(function()
				getCallCount += 1
				if getCallCount == 1 then
					error(errorMessage, 0)
				else
					return Promise.resolve('{"part":1}')
				end
			end)

			local promise = Files.read({
				store = store,
				file = file,
			})
			jest.runAllTimers()
			return expect(promise).rejects.toMatch(errorMessage)
		end)

		it("should handle missing shards during read", function()
			local file = { shard = "testShard2", count = 2 }
			local getCallCount = 0

			local mockGet = MockDataStoreService.mockStoreMethod(mockData, "GetAsync", jest)
			mockGet.mockImplementation(function()
				getCallCount += 1
				if getCallCount == 1 then
					return Promise.resolve(nil)
				else
					return Promise.resolve('{"part":1}')
				end
			end)

			local promise = Files.read({
				store = store,
				file = file,
			})
			jest.runAllTimers()
			return expect(promise).rejects.toMatch("Missing shard")
		end)
	end)

	describe("utf8", function()
		it("should correctly encode and decode UTF-8 strings", function()
			local data = "Hello, 你好, مرحبا"
			local filePromise = Files.write({
				store = store,
				data = data,
				maxShardSize = 10,
				key = "testKey",
			})

			jest.runAllTimers()

			local promise = Files.read({
				store = store,
				file = filePromise:expect(),
			})

			jest.runAllTimers()

			return expect(promise).resolves.toEqual(data)
		end)
	end)
end)
