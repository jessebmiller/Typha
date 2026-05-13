# Module Diagram

```mermaid
graph TB
    Client([Client TCP])
    Peers([Peer Nodes])
    Operator([Operator])

    subgraph Transport
        wire["wire.zig\nframe parse / emit"]
        conn["connection.zig\nper-stream credits + lifecycle"]
    end

    subgraph Orchestration
        main["main.zig\nCLI entry"]
        node["node.zig\nevent loop · static alloc root"]
        cluster["cluster.zig\nshard topology · key routing"]
        shard["shard.zig\nper-shard coordination"]
    end

    subgraph Consensus
        vsr["vsr.zig\nVSR protocol"]
    end

    subgraph Operations
        sm["state_machine.zig\napply committed ops\nassigns seq + timestamp"]
        sub["subscribe.zig\nsubscription registry"]
    end

    subgraph Storage
        idx["index.zig\nin-memory entity hash index"]
        seg["segment_log.zig\nappend-only segment files"]
    end

    admin["admin.zig\nPayloadRedact · EntityLogDelete"]

    subgraph Foundation ["Foundation (imported by all)"]
        types["types.zig\nEvent · Filter · Cursor · MessageType"]
        consts["constants.zig\nSEGMENT_FILE_BYTES · MAX_PAYLOAD_BYTES · QUORUM"]
    end

    Client -->|"APPEND / READ / SUBSCRIBE\nCREDITS / CANCEL / PING"| wire
    wire <--> conn
    conn --> node
    main --> node
    node --> cluster
    cluster --> shard

    node -->|Append op| vsr
    vsr <-->|"PrepareReq · PrepareOk\nCommitReq · ViewChange\nRecovery"| Peers
    vsr -->|"apply(op)"| sm
    sm --> seg
    sm --> idx
    sm -->|notify on commit| sub
    sub --> conn

    node -->|"Read + Subscribe historical\n(bypasses VSR)"| idx
    idx --> seg

    Operator -->|operator credentials| admin
    admin --> seg
    admin --> idx
```

## Key design points

- **`state_machine.zig` is the VSR/storage seam.** The only code that assigns seq numbers; I-1/I-2/I-3 assertions live here and in `segment_log.zig`.
- **Reads bypass VSR entirely.** `node.zig` goes straight to `index.zig` → `segment_log.zig` with no consensus round-trip.
- **Subscribe has two phases.** Historical catch-up is a direct storage read (same path as Read). Live delivery is a `notify` callback from `state_machine.zig` on each commit, routed through `subscribe.zig` → `connection.zig`.
- **Admin is isolated from the client protocol.** The only entry point is `Operator → admin.zig`; there is no wire-layer path to these operations.
- **`sim/` is not shown.** It is a parallel build target that replaces the I/O layer under `vsr.zig` and `node.zig` with deterministic fakes; it does not add new module-level dependencies.
