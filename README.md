# Typha

A distributed, append-only event store.

## Status

**Design / specification phase.** No code yet. The formal spec, requirements, and architecture decisions are in [`docs/`](docs/).

---

## Data Model

Every event belongs to an **entity**, identified by a `(entity_type, entity_id)` pair. The store maintains a separate ordered log for each entity. Within a log, events are numbered starting at 1 with no gaps. Sequence numbers are permanent and immutable once assigned.

```
Event = {
    entity_type : string       -- e.g. "Order", "Account"
    entity_id   : bytes        -- client-assigned; any opaque bytes
    seq         : u64          -- 1, 2, 3, ... per entity; never reused
    timestamp   : i64          -- nanoseconds since Unix epoch (leader clock)
    payload     : bytes        -- opaque; the store does not interpret it
}
```

Entity IDs are owned by the client. The store assigns only sequence numbers and timestamps.

---

## Operations

### Append

```
Append(entity_type, entity_id, payload)
    -> (sequence_number, timestamp_ns)
```

Returns only after the event is committed to a quorum of replicas. The returned sequence number is the event's permanent position in the log.

### Read

```
Read(filter: ALL | ByType(entity_type) | ByEntity(entity_type, entity_id),
     since?: cursor)
    -> ordered Stream<Event>
```

Returns all matching events in ascending order within each entity. The stream is finite and complete as of the moment the read begins. For `ByEntity`, `since` is a sequence number. Cursor type for broader filters is an open decision.

### Subscribe

```
Subscribe(filter: ALL | ByType(entity_type) | ByEntity(entity_type, entity_id),
          since?: cursor)
    -> Stream<Event>
```

If `since` is provided, delivers all matching historical events after the cursor, then transitions seamlessly to live delivery. If omitted, delivers only events written after the subscription opens. Delivery is at-least-once. Within a single entity, events arrive in sequence order.

---

## Boundaries

No update. No delete. No cross-entity transactions. No payload inspection. No built-in projections. No schema management.

Two operator-only admin operations exist outside the client API for emergencies:

- **PayloadRedact** — overwrites a single event's payload bytes with a tombstone marker. The event remains in the log; sequence number and timestamp are preserved.
- **EntityLogDelete** — destroys all events for an entity and reclaims storage. Highest authorization bar.

Both require operator credentials and are fully audited.

---

## Architecture

### Language — Zig

No GC; latency is deterministic. Explicit allocators are a first-class language feature, enforcing the allocation discipline required — no dynamic allocation in the hot path.

### Storage — Segment Log + In-Memory Hash Index (Bitcask Model)

Each node stores its shard data as fixed-size, append-only segment files. An in-memory hash index maps `(entity_type, entity_id)` to a list of `(seq, file_offset)` pairs.

- Writes are always sequential appends.
- Reads are an index lookup followed by a sequential scan from the located offset.
- The index is fully recoverable by replaying segment files.

### Replication — Raft

The keyspace is divided into shards. Each shard is a Raft group of R replicas (default R = 3). A write is acknowledged only after `floor(R/2) + 1` nodes confirm it. The cluster tolerates `floor((R-1)/2)` failed nodes per shard while preserving availability.

---

## Guarantees

| Property | Guarantee |
|---|---|
| Durability | An acknowledged write survives any minority of node failures |
| Ordering | Sequence numbers are monotonically increasing, gapless, starting at 1, assigned in write-acceptance order |
| Immutability | Once acknowledged, seq, timestamp, and payload are permanent |
| Availability | Reads and writes continue as long as a quorum per shard is reachable |

Aspirational v1 latency targets: Append p99 < 10ms. Read first-byte p99 < 5ms.

---

## Open Decisions

| # | Question |
|---|---|
| OD-1 | Entity ID format — any bytes, UTF-8 only, or UUID-structured? |
| OD-2 | Max payload size |
| OD-3 | Replication factor — hardcoded 3 or operator-configurable? |
| OD-4 | Follower reads — strong consistency vs. stale follower reads? |
| OD-6 | Wire protocol — gRPC, custom TCP framing, or HTTP/2 bare? (HTTP/1.1 excluded; streaming required) |
| OD-7 (resolved) | Cross-entity cursor is `TimestampNs`; resume re-delivers from `T - SKEW_WINDOW` to handle clock skew |

---

## Documentation

- [`docs/requirements.md`](docs/requirements.md) — functional and non-functional requirements
- [`docs/spec.md`](docs/spec.md) — formal specification: definitions, invariants, operations, storage and failure models
- [`docs/decisions.md`](docs/decisions.md) — architecture decision records (ADRs)
