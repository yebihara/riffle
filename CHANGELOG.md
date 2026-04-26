# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Configurable Redis key prefix via `Configuration#redis_key_prefix` (default `"riffle"`) and `Store::Redis.new(key_prefix: ...)` per-instance override.
- `PageFetcher.new(relation:)` keyword to preserve `includes` / `joins` / `select` / additional `where` clauses across page navigation. `model_class:` continues to work for the legacy no-scope path.
- `Configuration#on_max_ids_exceeded` (`:truncate` default, `:raise` opt-in) plus a `truncated` flag persisted alongside the cursor and exposed via `Store::Base#truncated?` and `PageFetcher::Result#truncated?`.
- `Riffle::MaxIdsExceeded` error type (raised when `:raise` mode trips).
- `Store::Base#remove_ids_and_decrement` — atomic-by-pair backfill removal that decrements counts by the actual ZREM count, guarding against concurrent double-decrement.
- Test infrastructure: spec/support/active_record.rb, spec/support/kaminari.rb, mock_redis-backed Redis store specs, full Pagy and Kaminari adapter specs.

### Changed
- **Renamed gem from `chikuden` to `riffle`** (module / namespace / file paths / Redis key prefix / log prefix all updated).
- Redis keys now use a `{cursor_id}` hash tag (`riffle:{CURSOR_ID}:ids` and `riffle:{CURSOR_ID}:meta`) so MULTI blocks succeed on Redis Cluster.
- `Store::Redis#fetch_page` no longer coerces results with `.to_i`. UUID / string-typed primary keys are returned as-is so ActiveRecord can cast them at WHERE-clause time.
- `PageFetcher` and the adapters now use `model_class.primary_key` / `klass.primary_key` instead of hardcoded `:id`.
- `PageFetcher#fetch` and `Snapshot#total_pages` now raise `ArgumentError` for non-positive `per_page` (was `FloatDomainError` via `Float::INFINITY.ceil`).
- `Store::Memory#store` now de-duplicates IDs to match Redis Sorted Set unique-member semantics; existing tests that intentionally passed duplicate IDs continue to pass.
- `Store::Memory#decrement_total_count` now also decrements `stored_count` (it previously only adjusted `total_count`, contradicting the Redis store contract).
- Bumped minimum Ruby to 3.1 and minimum Rails (railties / activesupport) to 7.0; older versions are EOL.

### Fixed
- **UUID / custom string primary keys are no longer corrupted** on the Redis store path (issue #001).
- **Original relation scope** (`includes`, `select`, `joins`, additional `where`) is preserved across page navigation; previous behavior issued the per-page WHERE against the bare model class, dropping all scope and causing N+1 (issue #002).
- Redis Cluster compatibility: MULTI blocks no longer trip CROSSSLOT (issue #003).
- max_ids truncation is no longer silent — emits a WARN log and surfaces via `Result#truncated?` (issue #004).
- `per_page=0` (and other non-positive values) raise `ArgumentError` cleanly instead of crashing with `FloatDomainError` (issue #005).
- Backfill `total_count` no longer double-decrements under concurrent requests, and the count update is atomic-by-pair (issues #008 + #009).

### Removed
- Dead code: `lib/riffle/adapters/kaminari/railtie.rb` (never required), `Riffle::CursorNotFound` (defined but never raised), `Riffle::Current.per` (defined but never used) (issue #013).

## [0.1.0] - 2026-02-07

### Added
- Initial release as `chikuden`.
- Redis Sorted Set based ID caching with snapshot semantics across page navigation.
- Kaminari adapter (controller macro, relation extension, view helpers).
- Pagy adapter (backend, frontend).
- In-memory store for testing.
- Backfill mechanism for records deleted between snapshot creation and page fetch.

[Unreleased]: https://github.com/yebihara/riffle/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yebihara/riffle/releases/tag/v0.1.0
