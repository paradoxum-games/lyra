# Changelog

## 0.6.0
* Added `updateImmutable`, `updateImmutableAsync`, `txImmutable`, `txImmutableAsync` APIs
  * This 'immutable' flavor of API lets you avoid deep copying, but forces you to handle copy-on-write semantics yourself. Instead of returning `true` to commit a change, you return a new copy of the data containing the desired changes.
* Removed `splitUtf8String` implementation in favor of a simpler implementation
* BREAKING: Removed `disableReferenceProtection` in favor of smarter utilization of frozen tables
* Changed changedCallbacks to reconcile mutable changes into a copy-on-write table, making nested change detection easier
* Fixed t absolute requires

## 0.5.0-rc.0
* Commented (almost) the entire codebase
* Expanded Moonwave generated API docs
* Added .luaurc ([#5](https://github.com/paradoxum-games/lyra/issues/5), thanks [@ffrostfall](https://github.com/ffrostfall)!)
* Change changedCallbacks to be -> () instead of -> () -> () ([#4](https://github.com/paradoxum-games/lyra/issues/4), thanks [@ffrostfall](https://github.com/ffrostfall)!)
* Fixed a race condition with locks and added tests for it
* Fixed Promise absolute require ([#3](https://github.com/paradoxum-games/lyra/issues/3), thanks [@ffrostfall](https://github.com/ffrostfall)!)

## 0.4.1
* Added tests for changedCallbacks
* Simplified orphaned file cleanup implementation
* Added file cleanup integration tests

## 0.4.0
* Added `PlayerStore:peek(userId)`, which returns a player's data without loading it into the store
* Added `disableReferenceProtection` option to `PlayerStore.new()`, which improves performance by omitting a deep copy during updates
* Changed sharding to use JSON encoded buffers for compression
* Fixed a bug where buffers wouldn't be copied for atomic updates

## 0.3.3
* Initial release
