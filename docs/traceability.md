# Traceability Matrix

Maps every requirement to the invariants that enforce it, the architecture that implements it, and the planned modules and tests that verify it. This document is the single source of truth for requirement coverage; it is updated alongside any change to `requirements.md`, `spec.md`, or `architecture.md`.

## How to Read This Table

- **ID** — the requirement identifier from `requirements.md`
- **Invariants** — the `spec.md` invariants that must hold for this requirement to be satisfied
- **Architecture** — the section(s) of `architecture.md` that address implementation approach
- **Module (planned)** — the Zig source file(s) that will implement this requirement; fill in when the file is created
- **Assertion Tags** — `// I-N:` comment tags that must appear on assertions in code enforcing this requirement; greppable by `scripts/check_traceability.zig`
- **Tests (planned)** — test function names that will verify this requirement; fill in when tests are written
- **Blocked by** — open decisions that must be resolved before implementation is complete

## Requirements

| ID | Requirement | Invariants | Architecture | Module (planned) | Assertion Tags | Tests (planned) | Blocked by |
|----|-------------|------------|--------------|------------------|---------------|-----------------|------------|
| FR-1 | Append: write event, return seq + timestamp | I-1, I-2, I-3 | Storage Engine; Replication — VSR; Latency Budget | `src/state_machine.zig`, `src/segment_log.zig`, `src/vsr.zig` | `// I-1:` `// I-2:` `// I-3:` | `test_append_sequence_gapless`, `test_append_no_duplicate`, `test_append_durable_quorum` | — |
| FR-2 | Read: ordered event stream from filter + cursor | I-1, I-4 | Storage Engine; Reads — Leader Only; Wire Protocol; Latency Budget | `src/read.zig`, `src/index.zig`, `src/segment_log.zig` | `// I-1:` `// I-4:` | `test_read_ordered`, `test_read_cursor_resume`, `test_read_complete_as_of_start` | — |
| FR-3 | Subscribe: live stream with optional historical catch-up | I-1, I-4 | Storage Engine; Wire Protocol | `src/subscribe.zig`, `src/segment_log.zig` | `// I-1:` `// I-4:` | `test_subscribe_catchup_no_gap`, `test_subscribe_live_delivery`, `test_subscribe_at_least_once` | — |
| FR-4 | Boundaries: PayloadRedact and EntityLogDelete (operator-only, audited) | I-3 (audited exception) | Admin Operations — Two Separate Ops | `src/admin.zig` | (admin ops are audited exceptions, not invariant assertions) | `test_admin_requires_credentials`, `test_admin_audit_trail`, `test_admin_not_client_accessible`, `test_payload_redact_preserves_seq_timestamp`, `test_entity_log_delete_notifies_readers` | — |
| NFR-Dur | Durability: acknowledged write survives minority node failure | I-3 | Replication — VSR; Failure Model (spec) | `src/vsr.zig` | `// I-3:` | `test_durability_minority_failure`, `test_durability_quorum_write` | — |
| NFR-Ord | Ordering: seq gapless from 1, no duplicates, determines event order | I-1, I-2, I-4 | Storage Engine | `src/segment_log.zig`, `src/state_machine.zig` | `// I-1:` `// I-2:` `// I-4:` | `test_ordering_gapless`, `test_ordering_no_duplicate`, `test_ordering_seq_not_timestamp` | — |
| NFR-Imm | Immutability: seq, timestamp, payload fixed after Append returns | I-3 | Storage Engine (append-only files) | `src/segment_log.zig`, `src/state_machine.zig` | `// I-3:` | `test_immutability_post_append`, `test_immutability_segment_read_back` | — |
| NFR-Scl | Scalability: write throughput and storage scale by adding shards | — | Replication — VSR (independent shard groups) | `src/shard.zig`, `src/cluster.zig` | — | `test_scale_shard_routing`, `test_scale_independent_groups` | — |
| NFR-Avl | Availability: reads and writes continue while quorum reachable | — | Replication — VSR (quorum commit) | `src/vsr.zig` | — | `test_availability_quorum_intact`, `test_availability_minority_partition` | — |
| NFR-Trn | Transport: streaming with backpressure; no HTTP/1.1 | — | Wire Protocol — Custom TCP Framing | `src/wire.zig`, `src/connection.zig` | — | `test_transport_streaming`, `test_transport_backpressure`, `test_transport_long_lived` | — |
| NFR-Lat | Latency: Append p99 < 10ms; Read first-byte p99 < 5ms | — | Latency Budget | all hot paths | — | `test_latency_append_p99`, `test_latency_read_first_byte_p99` | — |

## Invariant Coverage Summary

Every spec invariant must appear in at least one row above. This section is a quick sanity check.

| Invariant | Covered by |
|-----------|------------|
| I-1: seq is {1..n}, gapless, starting at 1 | FR-1, FR-2, FR-3, NFR-Ord |
| I-2: no duplicate seq within an entity | FR-1, NFR-Ord |
| I-3: seq, timestamp, payload immutable after Append | FR-1, FR-4 (exception), NFR-Dur, NFR-Imm |
| I-4: seq determines order, not timestamp | FR-2, FR-3, NFR-Ord |

## Open Decision Blockers

None. All open decisions resolved.
