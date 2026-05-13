# Requirements: Distributed Event Store

## Purpose

A purpose-built, distributed, append-only event store for event-sourced systems. Does exactly three things: append, read, subscribe. Everything else is out of scope.

## Clients

Domain services are the clients. They coordinate among themselves on event payload shape. The store does not interpret payloads.

## Functional Requirements

### FR-1: Append

Write an event to an entity's log.

- **Inputs:** `entity_type` (string), `entity_id` (bytes), `payload` (bytes)
- **Outputs:** `sequence_number` (u64), `timestamp_ns` (i64)
- **Semantics:** The event is durably written to a quorum of replicas before returning. The returned sequence number is the event's permanent, immutable position in the entity's log.

### FR-2: Read

Read events from an entity's log.

- **Inputs:** `entity_type`, `entity_id`, `since` (sequence_number, optional)
- **Outputs:** ordered stream of `(sequence_number, timestamp_ns, payload)`
- **Semantics:** Returns all events with `sequence_number > since`, in ascending order. If `since` is omitted, returns all events. The stream is finite and complete as of the moment the read begins.

### FR-3: Subscribe

Receive new events as they are written.

- **Inputs:** filter — one of `ALL`, `ByType(entity_type)`, or `ByEntity(entity_type, entity_id)`
- **Outputs:** ongoing stream of `(entity_type, entity_id, sequence_number, timestamp_ns, payload)`
- **Semantics:** Delivers every matching event written after the subscription opens. Delivery is at-least-once. Within a single entity, events are delivered in sequence number order. Cross-entity ordering is approximate (by leader-assigned timestamp, not guaranteed strict).

### FR-4: Nothing Else

No delete. No update. No transactions across entities. No payload inspection. No built-in projections. No schema management.

## Non-Functional Requirements

**Durability:** An acknowledged write (one that returned a sequence number) MUST survive the failure of any minority of nodes.

**Ordering:** Within an entity, sequence numbers are monotonically increasing, gapless, starting at 1, and assigned in write-acceptance order.

**Immutability:** Once acknowledged, an event's sequence number, timestamp, and payload are permanent and unchangeable.

**Scalability:** Write throughput and storage capacity scale horizontally by adding nodes and shards. No single-node bottleneck.

**Availability:** The cluster continues serving reads and writes as long as a quorum of replicas per shard is reachable.

**Latency (aspirational v1):** Append p99 < 10ms. Read first-byte p99 < 5ms.

## Open Decisions

| # | Decision | Notes |
|---|---|---|
| OD-1 | Entity ID format | Any bytes? UTF-8 only? UUID-structured? Affects index design. |
| OD-2 | Max payload size | Needs an upper bound to prevent unbounded memory allocation. |
| OD-3 | Replication factor | Hardcoded 3, or operator-configurable? |
| OD-4 | Follower reads | Read from leader only (strong consistency) or allow stale follower reads (lower latency option)? |
| OD-5 | Subscription resumption | Can a subscriber reconnect and resume from a sequence number, or does a new subscription only receive future events? |
| OD-6 | Wire protocol | gRPC, custom TCP framing, or HTTP/2? |
