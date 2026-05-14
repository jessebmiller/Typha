# Development Plan

Phases are ordered to validate the riskiest assumptions earliest. Each phase's checkpoint is a precondition for the next phase being trustworthy — do not advance until the checkpoint passes.

## Status

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Scaffolding | complete |
| 2 | Storage Engine | complete |
| 3 | Wire Protocol | not started |
| 4 | Single-Node End-to-End | not started |
| 5 | Simulation Harness + VSR | not started |
| 6 | Multi-Node Integration | not started |
| 7 | Subscribe Live Delivery | not started |
| 8 | Admin + Traceability Script | not started |

---

## Phase 1 — Scaffolding

**Build:** `build.zig`, `types.zig`, `constants.zig`

`build.zig` defines two targets from day one: `typha` (the server) and `typha_sim` (simulation harness). All shared types (`Event`, `Filter`, `Cursor`, `MessageType`) and constants (`SEGMENT_FILE_BYTES`, `MAX_PAYLOAD_BYTES`, `QUORUM`) live here before anything else references them.

**Checkpoint:**
- [x] `zig build` is clean with no warnings
- [x] Every constant from the spec is defined and matches exactly: `SEGMENT_FILE_BYTES = 134217728`, `MAX_PAYLOAD_BYTES = 65536`, `QUORUM = floor(R/2) + 1`
- [x] Both build targets (`typha`, `typha_sim`) exist and link

---

## Phase 2 — Storage Engine

**Build:** `segment_log.zig`, `index.zig`

The foundation everything else rests on. Built in isolation — no network, no consensus, just file I/O and the hash index. The index recovery path (replay segments on startup) is the most critical property to validate here.

**Checkpoint:**
- [ ] Write 1M events across multiple segments; simulate a crash mid-write; replay from scratch; verify the recovered index is identical to the pre-crash state
- [ ] Property test: for any sequence of appends to a set of entities, I-1 (gapless seq from 1) and I-2 (no duplicates) hold after recovery
- [ ] Sequential write throughput and index lookup latency are measured and recorded — if storage alone can't hit sub-millisecond reads, the p99 targets are already dead

---

## Phase 3 — Wire Protocol

**Build:** `wire.zig`, `connection.zig`

Frame parsing and per-stream credit tracking, exercised in isolation before any real operations run through them.

**Checkpoint:**
- [ ] All message types round-trip through encode → decode without data loss or corruption
- [ ] Fuzz the frame parser: malformed lengths, truncated frames, oversized payloads — none crash or corrupt state
- [ ] Credit flow control: server holds at credit=0; sends exactly N events after `CREDITS(stream_id, N)`; pauses again
- [ ] Multiple streams on one connection are independent: a blocked stream (credit=0) does not stall others

---

## Phase 4 — Single-Node End-to-End

**Build:** `state_machine.zig` (R=1 path), `node.zig`, `cluster.zig`, `shard.zig`

Wire the storage engine and protocol together for R=1 (no consensus). This gives a working, testable system before VSR adds complexity. All invariant assertions in `state_machine.zig` must be in place here — they are easier to validate without consensus noise.

**Checkpoint:**
- [ ] Client connects, appends 10K events to 1K entities, reads them back, subscribes and receives live events; all invariants hold
- [ ] `grep -r '// I-' src/` shows I-1, I-2, I-3 tags on assertions in `state_machine.zig` and `segment_log.zig`
- [ ] Single-node Append p99 and Read first-byte p99 are measured and recorded; both should comfortably beat the targets (target headroom: <3ms Append, <2ms Read) before replication overhead is added

---

## Phase 5 — Simulation Harness + VSR

**Build:** `sim/network.zig`, `sim/clock.zig`, `sim/sim.zig`, `vsr.zig`

Built together. VSR without simulation is unverifiable; simulation without VSR has nothing to exercise. The sim harness replaces real I/O under `vsr.zig` with deterministic fakes — controllable network (drop, delay, reorder, partition) and a stepped clock. This is the longest and hardest phase.

**Checkpoint:**
- [ ] Simulate a 3-node cluster through all failure scenarios: leader crash mid-prepare, follower crash, network partition (minority isolated), message reorder, duplicate delivery
- [ ] Every scenario terminates with no invariant violation and a consistent log across all surviving replicas
- [ ] View changes complete correctly: a new leader picks up exactly where the old one left off
- [ ] Recovery: a crashed node that rejoins replays missed ops and converges with the cluster
- [ ] 10K randomized fault scenarios complete with zero invariant violations

---

## Phase 6 — Multi-Node Integration

**Build:** VSR wired into `node.zig` for R > 1; multi-shard routing in `cluster.zig`

Replace the R=1 stub in `node.zig` with the real VSR path. Validate the full write path under replication.

**Checkpoint:**
- [ ] 3-node cluster on localhost: kill one node mid-write; the write either commits on the surviving quorum or is cleanly rejected — never silently lost
- [ ] Latency targets hold under replication load: Append p99 < 10ms, Read first-byte p99 < 5ms on NVMe
- [ ] Multi-shard routing: keys hash to the correct shard; cross-shard writes each reach the right VSR group

---

## Phase 7 — Subscribe Live Delivery

**Build:** `subscribe.zig`

Historical catch-up (storage reads) already works from Phase 4. This phase adds the live subscription registry and the seamless handoff from historical to live.

**Checkpoint:**
- [ ] Subscribe with a historical cursor; no event omitted at the seam between the last historical event and the first live event
- [ ] Subscribe survives a leader failover: after view change, live delivery resumes with no gap and no missed events
- [ ] At-least-once delivery confirmed: events may be redelivered at the cursor boundary; sequence number deduplication handles duplicates correctly
- [ ] EntityLogDelete: active subscribers receive an explicit end-of-stream, not a silent hang

---

## Phase 8 — Admin + Traceability Script

**Build:** `admin.zig`, `scripts/check_traceability.zig`

**Checkpoint:**
- [ ] PayloadRedact: payload replaced with tombstone; seq and timestamp unchanged; event still appears in reads with tombstone marker
- [ ] EntityLogDelete: log gone; storage reclaimed; active Read and Subscribe calls on that entity get explicit error or end-of-stream
- [ ] Neither admin operation is reachable via the client TCP protocol — confirmed by attempting to invoke them from a normal client connection and receiving an error
- [ ] `scripts/check_traceability.zig` passes: every `// I-N:` tag in `src/` has a matrix row; every matrix row's tags appear in at least one source file; every listed test name exists
- [ ] Traceability script added to CI and passing
