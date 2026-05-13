# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**Design / specification phase — no code yet.** The formal spec, requirements, and ADRs are in `docs/`. Implementation will be in Zig.

## What This Is

Typha is a distributed, append-only event store. Clients append events to per-entity logs, read event history, and subscribe to live event streams. The store assigns sequence numbers and timestamps; clients own entity IDs. The store never interprets payloads.

## Data Model

```
Event = {
    entity_type : string       -- e.g. "Order", "Account"
    entity_id   : string       -- client-assigned; UTF-8, max 64 bytes
    seq         : u64          -- 1, 2, 3, ... per entity; gapless, permanent
    timestamp   : i64          -- nanoseconds since Unix epoch (leader clock)
    payload     : bytes        -- opaque
}
```

Each `(entity_type, entity_id)` pair has its own ordered log. Sequence numbers start at 1 with no gaps; once assigned they never change.

## Architecture

**Language:** Zig. Chosen for deterministic latency (no GC), explicit allocators enforced by the language, and no hidden control flow. Rust was rejected (safety guarantees overlap with the allocation discipline already required); Go was rejected (GC pauses under write pressure).

**Storage per node (ADR-3):** Append-only segment log + in-memory hash index (Bitcask model). The index maps `(entity_type, entity_id)` → `[(seq, file_offset)]`. Writes are always sequential appends; reads are an index lookup + sequential scan. The index is fully recoverable by replaying segment files — no separate WAL needed. LSM trees were rejected because their complexity exists to handle updates/deletes, which this system never does in normal operation.

**Replication:** VSR per shard. A write is acknowledged only after `floor(R/2) + 1` replicas confirm it. Each shard is an independent VSR group; the keyspace is sharded horizontally. VSR chosen over Raft for deterministic round-robin leader election, which makes simulation testing tractable.

**Index memory:** 16 bytes per event (seq u64 + offset u64). 1 billion events ≈ 16 GB. Acceptable at design-time; if it becomes a constraint, a two-level index can be introduced without changing the on-disk format.

## Key Invariants (from `docs/spec.md`)

- `I-1`: Sequence numbers in any entity log are exactly `{1, 2, ..., n}` — gapless, starting at 1
- `I-2`: No duplicate sequence numbers within an entity
- `I-3`: Once `Append` returns, `seq`, `timestamp`, and `payload` are immutable — except via `PayloadRedact` or `EntityLogDelete` (operator-only, fully audited)
- `I-4`: Sequence numbers determine event order, not timestamps

## Admin Operations (outside the client API)

- **PayloadRedact**: Overwrites one event's payload with a tombstone. Seq/timestamp preserved. Use for accidental PII or leaked secrets.
- **EntityLogDelete**: Destroys all events for an entity and reclaims storage. Largest blast radius in the system. Active reads/subscribes for that entity receive explicit error or end-of-stream.

Both require operator credentials, full audit trail, and must be inaccessible via the normal client protocol.

## Open Decisions

None.

## Traceability

Every requirement has a row in `docs/traceability.md`. The matrix maps requirements → spec invariants → architecture → planned modules → planned tests. It is the single source of truth for requirement coverage.

**Maintaining the matrix — update it whenever you change any of these:**

| Change | Action |
|--------|--------|
| Add/modify a requirement in `requirements.md` | Add or update the corresponding row in the matrix |
| Add/modify an invariant in `spec.md` | Update the Invariants column for affected rows; add a row if nothing covers the new invariant; update the Invariant Coverage Summary table |
| Add/modify an architecture decision in `architecture.md` | Update the Architecture column for affected rows |
| Create a new source module | Fill in the Module column for the row(s) it implements |
| Write a test | Fill in the Tests column for the row(s) it covers |
| Resolve an open decision | Remove the blocker from the Blocked-by column and update Architecture/Module columns as needed |

**Tagging assertions in code:**

Every assertion that enforces a spec invariant must carry a tag comment: `// I-N: reason`. This makes coverage greppable.

```zig
assert(event.seq == log.len + 1); // I-1: seq must be exactly the next position, no gaps.
assert(event.seq != 0);           // I-1: seq starts at 1; zero is the sentinel for no events.
```

The Assertion Tags column in the matrix records which tags are expected in each module. Run `grep -r '// I-' src/` to audit coverage.

**Verification script (to be written at implementation start):** `scripts/check_traceability.zig` will:
1. Grep `src/` for all `// I-N:` tags and confirm each has a matrix row.
2. Confirm every row's Assertion Tags appear in at least one source file.
3. Confirm every test name in the Tests column exists as a `test "..."` or `fn test_...` declaration in `src/`.
4. Exit non-zero on any mismatch (run in CI).

## Tiger Style (the coding style for this project)

Full guide is in `docs/TIGER_STYLE.md`. The most important rules:

**Safety:**
- No recursion. Simple, explicit control flow only.
- Everything has a fixed upper bound — all loops, all queues. Assert the bound.
- Use `u32`, `u64`, etc. — not `usize`.
- **Assert aggressively**: minimum 2 assertions per function. Assert pre/postconditions and invariants. Pair assertions — enforce each property on at least two code paths (e.g., before writing to disk and after reading back).
- Assert the positive space you expect AND the negative space you do not expect.
- All memory statically allocated at startup. No dynamic allocation after initialization.
- Hard limit: **70 lines per function**. Push `if`s up and `for`s down — centralize control flow in the parent, keep helpers pure.
- All compiler warnings at the strictest setting.
- All errors must be handled.

**Performance:**
- Back-of-the-envelope sketches before implementation. Optimize for the slowest resource first (network > disk > memory > CPU).
- Batch. Control plane vs. data plane. Don't react to external events directly — run at your own pace.
- Hot loops go in standalone functions with primitive arguments (no `self`), so the compiler doesn't need to prove it can cache struct fields.

**Naming:**
- `snake_case` for functions, variables, file names.
- No abbreviations (except primitive integer args to sort/matrix functions).
- Units and qualifiers go last: `latency_ms_max`, not `max_latency_ms`.
- Related names should have the same character count so they align in source.
- Helper functions are prefixed with the calling function's name: `read_sector` / `read_sector_callback`.
- Struct layout: fields → types → methods. `main` goes first in a file.
- Callbacks go last in parameter lists.
- `options: struct` for functions taking two or more arguments of the same primitive type.

**Comments:**
- Always explain *why*, not *what*. Code explains what; comments explain the reasoning.
- Comments are full sentences with capital letters and periods.
- Tests should have a description explaining goal and methodology.
- Commit messages are the permanent record — PR descriptions are invisible in `git blame`.

**Dependencies:** Zero dependency policy (apart from the Zig toolchain). Scripts go in `scripts/*.zig`, not `scripts/*.sh`.

**Style mechanics:** `zig fmt`. 4-space indentation. 100-column hard limit. Braces on `if` unless it fits on one line.
