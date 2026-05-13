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
- **Semantics:** Returns all matching events, in ascending order within each entity. The stream is finite and complete as of the moment the read begins. For `ByEntity`, `since` is a sequence number. For `ByType` and `ALL`, `since` is a `TimestampNs`; resuming from cursor `T` re-delivers events from `T - SKEW_WINDOW` to cover clock skew across shard leaders. Clients must tolerate duplicate delivery when resuming.

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

**Ordering:** Within an entity, sequence numbers are monotonically increasing, gapless, starting at 1, and assigned in write-acceptance order.

**Immutability:** Once acknowledged, an event's sequence number, timestamp, and payload are permanent and unchangeable.

**Scalability:** Write throughput and storage capacity scale horizontally by adding nodes and shards. No single-node bottleneck.

**Availability:** The cluster continues serving reads and writes as long as a quorum of replicas per shard is reachable.

**Transport:** Streaming-only. The transport must support long-lived streams with client-controlled flow (backpressure). Request/response transports (HTTP/1.1) are excluded. This makes pagination via a `limit` parameter unnecessary — clients read at their own pace.

**Latency (aspirational v1):** Append p99 < 10ms. Read first-byte p99 < 5ms.

## Open Decisions

None.
