# Requirements: Distributed Event Store

## Purpose

An append-only event store for event-sourced systems. Clients append events, read event history, and subscribe to ongoing event streams. The store does not interpret payloads.

## Clients

Domain services are the clients. They coordinate among themselves on event payload shape.

## Functional Requirements

### FR-1: Append

Write an event to an entity's log.

- **Inputs:** `entity_type` (string), `entity_id` (bytes), `payload` (bytes)
- **Outputs:** `sequence_number` (u64), `timestamp_ns` (i64)
- **Semantics:** The event is durably written to a quorum of replicas before returning. The returned sequence number is the event's permanent, immutable position in the entity's log.

### FR-2: Read

Read events matching a filter.

- **Inputs:** `filter` (ALL | ByType(entity_type) | ByEntity(entity_type, entity_id)), `since` (cursor, optional)
- **Outputs:** ordered stream of `(entity_type, entity_id, sequence_number, timestamp_ns, payload)`
- **Semantics:** Returns all matching events, in ascending order within each entity. The stream is finite and complete as of the moment the read begins. For `ByEntity`, `since` is a sequence number. For broader filters, cursor semantics are TBD (see OD-7).

### FR-3: Subscribe

Receive events as they are written, with optional catch-up from history.

- **Inputs:** `filter` (ALL | ByType(entity_type) | ByEntity(entity_type, entity_id)), `since` (cursor, optional)
- **Outputs:** ongoing stream of `(entity_type, entity_id, sequence_number, timestamp_ns, payload)`
- **Semantics:** If `since` is provided, first delivers all matching historical events after the cursor, then transitions seamlessly to live delivery with no gap. If `since` is omitted, delivers only events written after the subscription opens. Delivery is at-least-once. Within a single entity, events are delivered in sequence number order. Cross-entity ordering is approximate (by leader-assigned timestamp, not guaranteed strict).

### FR-4: Boundaries

No delete. No update. No cross-entity transactions. No payload inspection. No built-in projections. No schema management.

Two operator-only admin operations exist outside the client API:

- **PayloadRedact:** overwrites the payload of a single event with a tombstone marker. Sequence number, timestamp, and event count are preserved. Requires operator credentials; fully audited.
- **EntityLogDelete:** destroys all events for an entity and reclaims storage. Active readers and subscribers for that entity receive an explicit error or end-of-stream. Highest authorization bar; fully audited.

## Non-Functional Requirements

**Durability:** An acknowledged write (one that returned a sequence number) MUST survive the failure of any minority of nodes.

// NOTE does the system require sequence numbers to be gapless or start at 1? Let's not constrain our implementation unless we gain something from it
**Ordering:** Within an entity, sequence numbers are monotonically increasing, gapless, starting at 1, and assigned in write-acceptance order.

**Immutability:** Once acknowledged, an event's sequence number, timestamp, and payload are permanent and unchangeable.

**Scalability:** Write throughput and storage capacity scale horizontally by adding nodes and shards. No single-node bottleneck.

**Availability:** The cluster continues serving reads and writes as long as a quorum of replicas per shard is reachable.

**Transport:** Streaming-only. The transport must support long-lived streams with client-controlled flow (backpressure). Request/response transports (HTTP/1.1) are excluded. This makes pagination via a `limit` parameter unnecessary — clients read at their own pace.

**Latency (aspirational v1):** Append p99 < 10ms. Read first-byte p99 < 5ms.

## Open Decisions

| # | Decision | Notes |
|---|---|---|
| OD-1 | Entity ID format | Any bytes? UTF-8 only? UUID-structured? Affects index design. |
| OD-2 | Max payload size | Needs an upper bound to prevent unbounded memory allocation. |
| OD-3 | Replication factor | Hardcoded 3, or operator-configurable? |
| OD-4 | Follower reads | Read from leader only (strong consistency) or allow stale follower reads (lower latency option)? |
| OD-6 | Wire protocol | Must support streaming (HTTP/1.1 excluded). Options: gRPC, custom TCP framing, HTTP/2 bare. |
| OD-7 (resolved) | Cross-entity cursor type | `TimestampNs`. Resuming from cursor T re-delivers events from `T - SKEW_WINDOW` to cover clock skew across shard leaders. Duplicate delivery is acceptable under the existing at-least-once guarantee. `SKEW_WINDOW` is an operator-configured parameter (expected: low single-digit seconds). |
