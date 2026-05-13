# Architecture

Design rationale for the major decisions in Typha.

## Language — Zig

The dominant SLOs are write p99/p999 and read p99 latency. The primary threat to tail latency in a high-throughput system is GC pauses, which are unpredictable and worsen under load.

Zig provides: no GC (deterministic latency), explicit allocators as a first-class language feature (enforcing the allocation discipline the design requires), no hidden control flow, no exceptions, no implicit allocations. TigerBeetle — a purpose-built financial ledger with similar design constraints — is the existence proof for this approach.

Rust was considered and rejected: its safety guarantees overlap significantly with the allocation discipline and simulation testing strategy already required by the design, making the ergonomic cost hard to justify ("belt and overalls"). Go was considered and rejected: GC pauses, while small in modern Go, are real and worsen under write throughput pressure.

Simulation testing is the primary correctness strategy for the distributed protocol layer.

## Latency Budget (Back-of-the-Envelope)

Target SLOs: Append p99 < 10ms, Read first-byte p99 < 5ms. Resource order: network > disk > memory > CPU.

**Append critical path** (client → leader → quorum → ack):
- Network: one client→leader RTT (~1ms LAN) + parallel replication to 2 followers (~1ms)
- Disk: one sequential append on leader before ack (~0.1ms NVMe, ~2ms commodity SSD)
- Total typical: ~2–3ms. p99 with queuing: ~5–8ms. Feasible on NVMe + LAN; tight on spinning disk.

**Read critical path** (client → leader → index lookup → disk read → first byte):
- Network: one client→leader RTT (~1ms)
- Memory: index lookup is pure in-memory hash map (~0.1ms including cache miss)
- Disk: sequential read from located offset — no seek penalty due to Bitcask layout (~0.1ms NVMe)
- Total typical: ~1–2ms. p99 ~3–4ms. Feasible.

**Throughput sanity check** (assuming 1 KB average payload):
- Disk: 100K appends/s × ~1 KB = ~100 MB/s sequential write. NVMe sequential write bandwidth is 2–5 GB/s — not a bottleneck.
- Network: 100K appends/s × ~1 KB × 3 replicas = ~300 MB/s replication traffic. Requires 10 GbE (1.25 GB/s); Gigabit Ethernet (125 MB/s) is insufficient at this throughput. Node NICs must be 10 GbE or better.

## Reads — Leader Only

All reads are served by the shard leader. Follower reads were considered and rejected.

The two correct approaches to follower reads are read-index (the follower asks the leader for the current commit index, then waits until it has caught up before serving the read) and lease-based reads (the leader holds a time-bounded lease guaranteeing no other leader exists, followers serve reads within the lease window). Read-index largely negates the latency benefit — the follower still contacts the leader on every read. Lease-based reads are correct only when clock skew is bounded tighter than the lease duration, which is an operational constraint that conflicts with the design goal of simple, predictable behavior.

The read latency target (p99 < 5ms) is achievable from the leader alone given the budget: ~1ms network RTT + ~0.1ms index lookup + ~0.1ms disk read. Follower reads add complexity without meaningfully improving on a target that is already met.

## Replication — VSR over Raft

Each shard runs an independent VSR (Viewstamped Replication) group. VSR was chosen over Raft after evaluating the primary correctness strategy — simulation testing — against each protocol's properties.

Raft's case: a large body of prior art, formal proofs (Ongaro's dissertation, TLA+ models), and wide production adoption. These proofs demonstrate that the protocol is correct; they say nothing about whether a specific implementation of it is correct.

VSR's case: deterministic leader election via round-robin view change. No randomized election timeouts. In a simulation harness (VOPR-style), this means every possible failure sequence is reachable and reproducible without fighting non-determinism in the protocol itself. The simulation can exercise every code path rather than waiting for random timeouts to fire.

The deciding factor: simulation testing validates the implementation, not the protocol. A correct protocol with a buggy implementation is still buggy. VSR's determinism makes the implementation testable in a way that Raft's randomized timeouts make harder. TigerBeetle — the closest prior art in Zig, under identical design constraints — makes the same choice.

Scoped message types for Typha: PrepareRequest, PrepareOk, CommitRequest, StartViewChange, DoViewChange, StartView, RecoveryRequest, RecoveryResponse, AppendRequest (client), AppendResponse (client), ReadRequest (client), ReadResponse (client). Approximately 12 message types — a tractable, bounded surface area for a bespoke implementation.

## Entity ID Ownership — Client-Managed

The store's job is to append and retrieve events, not to generate identifiers — that is a client-layer concern. Clients with an existing canonical domain ID (order ID, account ID, etc.) use it directly; clients that need ID generation can handle it in a client library. The core system stays simple either way.

Consequence: the store does not detect or prevent ID collisions within an entity type. Two clients writing to the same `(entity_type, entity_id)` append to the same log, which may be intentional (concurrent writers) or a bug.

## Storage Engine — Segment Log + Hash Index (Bitcask Model)

The Bitcask model is a direct fit for a pure append workload: writes are always sequential appends (fastest possible disk I/O); reads are an index lookup followed by a sequential scan from the located offset. The index is memory-resident and fully recoverable by replaying segment files, eliminating the need for a separate write-ahead log.

LSM trees were rejected: their complexity exists to handle updates and deletes efficiently, which this system never does in normal operation. The storage layer has zero external dependencies — it is a small, well-understood piece of code owned entirely by the project.

Segment file size is fixed at 128 MB. This matches TigerBeetle's choice under identical design constraints (deterministic latency, no GC, no updates, fast crash recovery). Kafka uses 1 GB segments and Bitcask defaults to 2 GB — both figures are driven by compaction amortization costs that do not apply here (Kafka retains data for days; Bitcask rewrites segments to reclaim space from overwritten keys). Because Typha is append-only with no compaction, there is no benefit to large segments. 128 MB keeps recovery fast: at ~1 GB/s NVMe sequential read speed, replaying one segment takes ~130ms. It also makes timestamp-range metadata (min/max timestamp per segment) more precise, reducing unnecessary segment reads.

Index memory: each value entry is 16 bytes (seq u64 + offset u64), so 1 billion events across all entities on a node requires ~16 GB for value storage. Key storage adds (entity_type + entity_id) bytes per distinct entity, not per event — with bounded key lengths (see spec definitions) and far fewer distinct entities than events, key overhead is negligible relative to value storage. Total index memory is dominated by event count × 16 bytes. This is manageable with appropriate shard sizing. If it becomes a constraint, a two-level index (entity → segment range, then scan within segment) can be introduced without changing the on-disk format.

## Admin Operations — Two Separate Ops

PayloadRedact and EntityLogDelete are kept separate because they address distinct problems, violate different invariants, and have different blast radii:

- **PayloadRedact** is a narrow carve-out: the event remains in the log, only the payload bytes change. Use for accidental PII or leaked secrets.
- **EntityLogDelete** destroys the entire entity log. Use for DDoS mitigation or bulk junk removal.

Conflating them into a single "admin delete" operation would obscure these differences for implementors and operators.

Both operations must be: inaccessible via the normal client protocol, gated on operator credentials, and fully audited (who, what, when, why).

Proactive alternative for PII: clients should encrypt sensitive fields before appending and store the encryption key separately (crypto-shredding). To erase the data, destroy the key. The payload in the store becomes permanently unreadable without any store operation. PayloadRedact is the escape hatch for when this was not done.

## Constant and Type Rationale

**`SequenceNo = u64, >= 1` (starts at 1, not 0):** Zero is the sentinel for "no events yet," usable without a nullable type at call sites. Starting at 1 preserves 0 as an unambiguous out-of-band value across the codebase.

**`TimestampNs = i64`:** Nanoseconds since Unix epoch. Signed to represent pre-epoch timestamps correctly; using u64 would make negative values undefined behavior and silently corrupt historical data from systems with pre-1970 records.

**`SKEW_WINDOW = u64`:** A clock skew bound in nanoseconds. u32 tops out at ~4.29 seconds, which is too tight for a configurable operator parameter (expected range: 1–5 seconds, i.e. 10⁹–5×10⁹ ns). u64 arithmetic is native on 64-bit hardware and no slower than u32.

**`EntityID = UTF-8 string, max 64 bytes`:** String IDs are the industry standard (EventStoreDB, Axon, Marten all use string stream/aggregate IDs). They are human-readable in logs, traces, and dashboards. The 64-byte maximum is double a hyphenated UUID string (36 bytes) — covers all common schemes (UUID, ULID at 26 chars, NanoID at 21 chars, natural domain IDs) with no known scheme exceeding this. Clients with raw binary IDs hex-encode them, which is one line of code.

**`EntityType = UTF-8 string, max 128 bytes`:** Entity type names are short by nature (e.g. "Order", "ShipmentEvent") — 128 bytes is generous headroom that keeps static key buffers small.

**`MAX_PAYLOAD_BYTES = 65536` (64 KB):** Measured against real-world payloads: a complex FedEx tracking webhook with 24 scan events is ~31 KB. AWS SQS hard limit is 256 KB; Kafka's default is 1 MB. 64 KB is conservative relative to the industry, keeping static per-connection append buffers cheap. Clients with payloads exceeding this limit use the Claim Check pattern: store the large content in object storage, append a content-addressed reference (URL or hash) as the event payload.

**`SEGMENT_FILE_BYTES = 134217728` (128 MB):** See Storage Engine section above.
