local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- rbxts_include
local Promise = require(script.Parent.Parent.Parent.Parent:WaitForChild("Promise"))

export type Status = "Started" | "Resolved" | "Rejected" | "Cancelled"

export type Promise = {
	andThen: (
		self: Promise,
		successHandler: (...any) -> ...any,
		failureHandler: ((...any) -> ...any)?
	) -> Promise,
	andThenCall: <TArgs...>(self: Promise, callback: (TArgs...) -> ...any, TArgs...) -> any,
	andThenReturn: (self: Promise, ...any) -> Promise,

	await: (self: Promise) -> (boolean, ...any),
	awaitStatus: (self: Promise) -> (Status, ...any),

	cancel: (self: Promise) -> (),
	catch: (self: Promise, failureHandler: (...any) -> ...any) -> Promise,
	expect: (self: Promise) -> ...any,

	finally: (self: Promise, finallyHandler: (status: Status) -> ...any) -> Promise,
	finallyCall: <TArgs...>(self: Promise, callback: (TArgs...) -> ...any, TArgs...) -> Promise,
	finallyReturn: (self: Promise, ...any) -> Promise,

	getStatus: (self: Promise) -> Status,
	now: (self: Promise, rejectionValue: any?) -> Promise,
	tap: (self: Promise, tapHandler: (...any) -> ...any) -> Promise,
	timeout: (self: Promise, seconds: number, rejectionValue: any?) -> Promise,
}

export type TPromise<T... = ...any> = {
	andThen: (self: Promise, successHandler: (T...) -> ...any, failureHandler: ((...any) -> ...any)?) -> Promise,
	andThenCall: <TArgs...>(self: Promise, callback: (TArgs...) -> ...any, TArgs...) -> Promise,
	andThenReturn: (self: Promise, ...any) -> Promise,

	await: (self: Promise) -> (boolean, T...),
	awaitStatus: (self: Promise) -> (Status, T...),

	cancel: (self: Promise) -> (),
	catch: (self: Promise, failureHandler: (...any) -> ...any) -> Promise,
	expect: (self: Promise) -> T...,

	finally: (self: Promise, finallyHandler: (status: Status) -> ...any) -> Promise,
	finallyCall: <TArgs...>(self: Promise, callback: (TArgs...) -> ...any, TArgs...) -> Promise,
	finallyReturn: (self: Promise, ...any) -> Promise,

	getStatus: (self: Promise) -> Status,
	now: (self: Promise, rejectionValue: any?) -> Promise,
	tap: (self: Promise, tapHandler: (T...) -> ...any) -> Promise,
	timeout: (self: Promise, seconds: number, rejectionValue: any?) -> Promise,
}

type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ...any) -> SignalConnection,
}

type SignalConnection = {
	Disconnect: (self: SignalConnection) -> ...any,
	[any]: any,
}

export type ErrorKind = "ExecutionError" | "AlreadyCancelled" | "NotResolvedInTime" | "TimedOut"

type Error = {
	is: (anything: any) -> boolean,
	isKind: (anything: any, kind: ErrorKind) -> boolean,
	Kind: {
		ExecutionError: "ExecutionError",
		AlreadyCancelled: "AlreadyCancelled",
		NotResolvedInTime: "NotResolvedInTime",
		TimedOut: "TimedOut",
	},
}

type PromiseModule = {
	Error: Error,
	Status: {
		Started: Status,
		Resolved: Status,
		Rejected: Status,
		Cancelled: Status,
	},

	all: <T>(promises: { TPromise<T> }) -> TPromise<{ T }>,
	allSettled: <T>(promise: { TPromise<T> }) -> TPromise<{ Status }>,
	any: <T>(promise: { TPromise<T> }) -> TPromise<T>,
	defer: <TReturn...>(
		executor: (
			resolve: (TReturn...) -> (),
			reject: (...any) -> (),
			onCancel: (abortHandler: (() -> ())?) -> boolean
		) -> ()
	) -> TPromise<TReturn...>,
	delay: (seconds: number) -> TPromise<number>,
	each: <T, TReturn>(
		list: { T | TPromise<T> },
		predicate: (value: T, index: number) -> TReturn | TPromise<TReturn>
	) -> TPromise<{ TReturn }>,
	fold: <T, TReturn>(
		list: { T | TPromise<T> },
		reducer: (accumulator: TReturn, value: T, index: number) -> TReturn | TPromise<TReturn>
	) -> TPromise<TReturn>,
	fromEvent: <TReturn...>(
		event: Signal<TReturn...>,
		predicate: ((TReturn...) -> boolean)?
	) -> TPromise<TReturn...>,
	is: (object: any) -> boolean,
	new: <TReturn...>(
		executor: (
			resolve: (TReturn...) -> (),
			reject: (...any) -> (),
			onCancel: (abortHandler: (() -> ())?) -> boolean
		) -> ()
	) -> TPromise<TReturn...>,
	onUnhandledRejection: (callback: (promise: TPromise<any>, ...any) -> ()) -> () -> (),
	promisify: <TArgs..., TReturn...>(callback: (TArgs...) -> TReturn...) -> (TArgs...) -> TPromise<TReturn...>,
	race: <T>(promises: { TPromise<T> }) -> TPromise<T>,
	reject: (...any) -> TPromise<...any>,
	resolve: <TReturn...>(TReturn...) -> TPromise<TReturn...>,
	retry: <TArgs..., TReturn...>(
		callback: (TArgs...) -> TPromise<TReturn...>,
		times: number,
		TArgs...
	) -> TPromise<TReturn...>,
	retryWithDelay: <TArgs..., TReturn...>(
		callback: (TArgs...) -> TPromise<TReturn...>,
		times: number,
		seconds: number,
		TArgs...
	) -> TPromise<TReturn...>,
	some: <T>(promise: { TPromise<T> }, count: number) -> TPromise<{ T }>,
	try: <TArgs..., TReturn...>(callback: (TArgs...) -> TReturn..., TArgs...) -> TPromise<TReturn...>,
}

return (Promise :: any) :: PromiseModule
