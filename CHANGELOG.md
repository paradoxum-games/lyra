# Changelog

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
