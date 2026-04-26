# Benchmarks

Reproducible benchmarks demonstrating Riffle's performance characteristics.

## deep_pagination.rb

Compares plain Kaminari (`LIMIT/OFFSET`) against Riffle (cached ID list +
`WHERE id IN`) for shallow vs deep pagination on the same dataset.

```bash
$ bundle exec ruby benchmark/deep_pagination.rb            # 100k records
$ bundle exec ruby benchmark/deep_pagination.rb 30000      # 30k records
$ bundle exec ruby benchmark/deep_pagination.rb 1000000    # 1M records
```

The script seeds an in-memory SQLite database, takes the median of 5
iterations, and reports four numbers:

- Kaminari at page 1
- Kaminari at the middle page (deep pagination)
- Riffle at page 1 (cursor materialized once, then reused)
- Riffle at the middle page

### What to expect

- **Kaminari**: latency grows roughly linearly with page number — each
  query asks the DB to scan and discard `OFFSET` rows. The deep/shallow
  ratio is large.
- **Riffle**: latency is essentially flat — the deep/shallow ratio is
  ≈1.0x because page navigation is `O(log N + page_size)` regardless of
  page number.

The absolute numbers depend on storage and dataset size. SQLite-in-memory
(used here for portability) is unrealistically fast; on PostgreSQL or
MySQL with a large index the gap widens significantly.

### Caveats

- Uses Riffle's bundled in-memory store, not real Redis, so
  cross-process / network costs are not measured. The algorithmic
  shape (slice a cached ID array, then `WHERE id IN`) is identical to
  the Redis store, so the page=1 vs page=N relationship transfers; the
  absolute Riffle numbers will be higher in production.
- First-query cost (the initial `pluck` of all IDs) is paid once when
  the cursor is created and is **not** included in the per-page
  numbers above. That cost is the trade-off Riffle makes — see the
  README's "Why Riffle" section for the rationale.
