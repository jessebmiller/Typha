# Architecture Decision Records

## ADR-1: Implementation Language — Zig

**Status:** Accepted

**Context:** The dominant SLOs for this system are write p99/p999 latency and read p99 latency. The primary threat to tail latency in a high-throughput system is GC pauses, which are unpredictable and worsen under load. The system also requires precise control over memory allocation, file I/O, and network buffers.

**Decision:** Implement in Zig.

**Rationale:**
- No GC; latency is deterministic
- Explicit allocators are a first-class language feature, enforcing the allocation discipline the design requires (bounded, known allocations; no dynamic allocation in the hot path)
- No hidden control flow, no exceptions, no implicit allocations
- Tiger Beetle (a purpose-built financial ledger with similar design philosophy) is the existence proof for this approach
- Rust was considered but rejected: its safety guarantees overlap significantly with the allocation discipline and simulation testing strategy already required by the design, making the ergonomic cost difficult to justify ("belt and overalls")
- Go was considered but rejected: GC pauses, while small in modern Go, are real and worsen under write throughput pressure

**Consequences:** Smaller hiring pool than Go or Rust. Younger ecosystem. Simulation testing (see ADR-4) becomes the primary correctness strategy for the distributed protocol layer, which Zig is well-suited for.

---

## ADR-2: Entity ID Ownership — Client-Managed

**Status:** Accepted

**Context:** Every write and most reads require identifying the target entity by (entity_type, entity_id). The question is whether the store generates entity IDs or clients provide them.

**Decision:** Entity IDs are provided by the client. The store assigns only sequence numbers (per-entity) and timestamps (per-event).

**Rationale:**
// NOTE I'd like to think through this assumption. There are definitnely circumstances where the client wants control of the ids but many clients will want their database to handle it, and many will use this as their database. Potentially client libraries though could handle id generation
- Domain services typically already have a canonical ID for their entities (order ID, customer ID, etc.) established before the first event is written
- Client-managed IDs allow embedding the same ID in related systems and event payloads without a round-trip to the store
// NOTE I don't think this is really true, often a client can wait for the write response to find out about the ID. The following is only true if they want to put the ID in the "create entity", the first, payload for a given entity
- Store-generated IDs would require a client to call the store before it has anything to write, just to obtain an ID
- Sequence numbers (store-assigned, monotonically increasing, gapless per entity) provide all the ordering guarantees the store needs to enforce

**Consequences:** Clients are responsible for ID uniqueness within an entity type. The store does not detect or prevent collisions — two clients writing to the same (entity_type, entity_id) append to the same log, which may be intentional (concurrent writers) or a bug.

---

## ADR-3: Storage Engine — Segment Log + Hash Index (Bitcask Model)

**Status:** Accepted

**Context:** The store needs an on-disk storage format for a single node's shard data. LSM trees (RocksDB, Pebble, LevelDB) are the common choice for embedded key-value storage. The question is whether they are appropriate here.

**Decision:** Use an append-only segment log with an in-memory hash index, following the Bitcask model. Do not use an LSM tree or any external storage engine dependency.

**Rationale:**
- LSM trees exist to handle updates and deletes efficiently. Events are immutable and never deleted in normal operation. LSM complexity buys nothing for a pure append workload.
- The Bitcask model is a direct fit: writes are always sequential appends (fastest possible disk I/O); reads are an index lookup followed by a sequential scan from the located offset.
- No external dependency. The storage layer is a small, well-understood piece of code we own entirely.
- The index (EntityType × EntityID → list of (seq, file_offset)) is memory-resident and can be fully reconstructed by replaying segment files, eliminating the need for a separate write-ahead log.
- Segment files are fixed-size and sealed when full, making them straightforward to replicate via Raft.

**Consequences:** The entire index must fit in memory. This is an acceptable constraint: an entry per event (seq u64 + offset u64 = 16 bytes) means 1 billion events across all entities on a node requires ~16GB of index memory, which is manageable with appropriate shard sizing. If this becomes a constraint, a two-level index (entity → segment range, then scan within segment) can be introduced without changing the on-disk format.

---

## ADR-4: Delete Escape Hatches — Two Separate Admin Operations

**Status:** Accepted

**Context:** The store is append-only and immutable by design. However, two operational emergencies require a controlled ability to remove data:

1. **Accidental PII or secrets in a payload** — regulatory or security obligation to erase specific content (GDPR right to erasure, leaked credentials)
2. **DDOS / junk flood** — an attacker or buggy client appends massive or numerous events, degrading performance for the whole node

These are distinct problems with different blast radii and different invariant violations.

**Decision:** Provide two separate operator-only administrative operations outside the normal client API:

### Op-A: PayloadRedact

Overwrites the payload bytes of a single event with a fixed TOMBSTONE marker. The event itself remains in the log. Sequence number, timestamp, and event count are all preserved. This is the minimum possible violation of immutability.

Use for: accidental PII, leaked secrets, targeted content erasure.

### Op-B: EntityLogDelete

Destroys all events for a given (entity_type, entity_id) and reclaims all storage for that entity. The entity log ceases to exist. Any active readers or subscribers for that entity receive an explicit error or end-of-stream signal.

Use for: DDOS mitigation, bulk junk removal, catastrophic client misbehavior.

**Rationale for keeping them separate:** They violate different invariants, have different blast radii, and warrant different authorization and audit requirements. Conflating them into a single "admin delete" operation would obscure these differences for implementors and operators.

**Proactive recommendation — Crypto-Shredding:** Clients who know they will handle PII should encrypt sensitive fields before appending, storing the encryption key in a separate system. To "erase" the data, destroy the key. The payload in the store becomes permanently unreadable without any store operation. PayloadRedact is the escape hatch for when this was not done.

**Consequences:** Both operations must be:
- Inaccessible via the normal client protocol
- Gated on explicit operator credentials
- Fully audited (who, what, when, why)
- Documented in operator runbooks

PayloadRedact creates a narrow carve-out in the immutability invariant (I-3). EntityLogDelete has the largest blast radius of any operation in the system and should require the highest authorization bar.
