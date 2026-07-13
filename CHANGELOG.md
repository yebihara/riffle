# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Changed (breaking)
- **Kaminari adapter redesigned around `ActiveRecord::Relation#extending`; the old global patches are gone** ([#7](https://github.com/yebihara/riffle/issues/7)). Removed the `riffle only:` controller macro, the request-global `Riffle::Current`, the every-model `.page` aliasing (`hooks.rb`), and the every-relation `RelationExtension` prepend. Riffle is now opt-in per model and per call site:
  - `include Riffle::Model` on a model (usually `ApplicationRecord`) adds a `.riffle(cursor:, param:, store:)` scope. Chain it **after** `.page`/`.per` — it must come after `.page` so its cursor-backed `total_count` wins over Kaminari's (Kaminari mixes `total_count` in at `.page` time, and Ruby resolves the later-added module first). Applying `.riffle` before `.page` raises `Riffle::ConfigurationError` when records load, instead of silently reporting the live table count; `.per` after `.riffle` is fine.
  - `riffle_page(relation, per:, page:, param:, store:)` controller helper replaces the macro, reading the page and cursor params from the request (symmetric with `pagy_riffle`).
  - Each `.riffle` produces an independent snapshot with its own `param:` (default `Riffle.config.cursor_param`), **fixing the request-global cursor corruption** that let two paginated collections in one action clobber each other's snapshots. View helpers (`paginate`, `riffle_cursor_field`, `riffle_path`) now read the relation's own `riffle_cursor_param`.
  - Works outside controllers (jobs, service objects) — no `params`/request required; pass `cursor:` directly. `other.merge(riffled_scope)` is unsupported (instance variables do not transfer through `merge`).

### Added
- GitHub Actions CI: runs the suite on Pagy 8, 9, and 43 with a real Redis service container ([#2](https://github.com/yebihara/riffle/issues/2)). The Redis store spec now honors `REDIS_URL` to run against a real server instead of mock_redis.
- Pagy 9 support: the adapter now detects the installed Pagy major and uses `:limit` (Pagy 9) or `:items` (Pagy 8) for the page-size var, request param, and `Pagy.new` keyword ([#1](https://github.com/yebihara/riffle/issues/1)).
- Pagy 43 support: a dedicated adapter (`backend_v43.rb` / `frontend_v43.rb`) built on the rewritten API — `Pagy::Offset` + `Pagy::Request` instead of `Pagy::Backend`, and the `:querify` option instead of the removed `pagy_url_for` to carry `cursor_id` into page links. `pagy_riffle` accepts both the keyword (`pagy_riffle(collection, **options)`) and trailing-positional-Hash (`pagy_riffle(collection, vars)`) calling styles ([#5](https://github.com/yebihara/riffle/issues/5)). Pagy 43 requires Ruby >= 3.3. Limit handling matches the 8/9 adapter: the `?limit=` request param is honored (and carried into page links, since Pagy 43 drops it otherwise), clamped by `:max_limit`, and takes precedence over a global `Pagy::OPTIONS[:limit]`. cursor_id/page/limit are read from the controller `#params` first (so JSON-body params and Symbol keys work), falling back to the Pagy request; callers exposing only `#params` (jobs, service objects) work without a `#request`.
- `Riffle::Adapters::Pagy.supported?` / `.limit_var` / `.v43?` version shim. Unsupported Pagy majors (7 and below, 10–42, 44 and above) log a warning and skip Pagy adapter setup instead of failing at runtime.
- `gemfiles/pagy_8.gemfile`, `gemfiles/pagy_9.gemfile`, and `gemfiles/pagy_43.gemfile` for running the suite against each supported Pagy major.
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
- Kaminari adapter (`RelationRiffle`): memoized fetch results no longer leak into relations derived via `.where` / `.per` / `.page` from a loaded riffle relation — `initialize_copy` resets the memoization (cursor state still rides along), so derived relations re-query instead of returning the parent's stale page.
- Kaminari adapter: chaining `.riffle` before `.page` now fails loudly at the `.page` call itself (via an `extending` override), closing the count-only path where Kaminari's shadowing `total_count` silently returned live counts; `.riffle` without Kaminari installed raises a descriptive `Riffle::ConfigurationError` when no `.limit` is given instead of `NameError: uninitialized constant Kaminari`.
- Pagy 43 adapter: `?page=0` / negative / non-numeric page params render page 1 again (clamped like `Pagy::Request#resolve_page`) instead of raising `Pagy::OptionError`; page/limit params nested under `:root_key` (JSON:API style) are resolved again; an explicitly passed `request:` option is no longer shadowed by the surrounding controller's `#params`; the params-fallback now delegates to `Pagy::Request#resolve_page` / `#resolve_limit` instead of re-implementing their resolution rules.
- Pagy 43 adapter: the limit injected into page links is nested under `:root_key` when one is set (canonical JSON:API form, matching where native Pagy writes page/limit params); direct requires of the adapter files now warn on unsupported Pagy majors like the railtie/extra path does.
- Requiring `riffle/adapters/pagy/backend` before the pagy gem no longer silently binds the 8/9 implementation: the dispatcher defers the version check to the first `pagy_riffle` call (and raises a clear `Riffle::ConfigurationError` if pagy is still absent). The frontend falls back to the legacy module, which is a safe superset on Pagy 43.
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
