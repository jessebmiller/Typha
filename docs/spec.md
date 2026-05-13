# Formal Specification: Distributed Event Store

## Definitions

```
EntityType   = non-empty UTF-8 string
EntityID     = non-empty byte sequence
SequenceNo   = u64, >= 1
TimestampNs  = i64 (nanoseconds since Unix epoch, leader wall clock)
Payload      = byte sequence, 0 < len <= MAX_PAYLOAD_BYTES

Event        = { entity_type: EntityType,
                 entity_id:   EntityID,
                 seq:         SequenceNo,
                 timestamp:   TimestampNs,
                 payload:     Payload }

Log(T, ID)   = the totally ordered sequence of Events where
               entity_type = T and entity_id = ID,
               ordered by seq

Filter       = ALL
             | ByType(T: EntityType)
             | ByEntity(T: EntityType, ID: EntityID)
```

## Invariants

These hold at all times across all nodes:

```
I-1  For all T, ID: seq numbers in Log(T, ID) are exactly {1, 2, ..., |Log(T, ID)|}
     (gapless, starting at 1)

I-2  For all T, ID, i != j: Log(T,ID)[i].seq != Log(T,ID)[j].seq
     (no duplicates within an entity)

I-3  Once Append returns seq S for entity (T, ID),
     Log(T,ID)[S] is immutable for all time,
     EXCEPT via operator-initiated PayloadRedact (payload bytes only)
     or EntityLogDelete (destroys the entire entity log).
     These are the only permitted violations; see Admin Operations.

I-4  For all T, ID: Log(T,ID)[i].seq < Log(T,ID)[j].seq => i < j
     (sequence numbers determine order, not timestamps)
```

## Operations

### Append

```
Append(T: EntityType, ID: EntityID, p: Payload)
  -> (S: SequenceNo, ts: TimestampNs)

Preconditions:
  T is non-empty
  ID is non-empty
  0 < |p| <= MAX_PAYLOAD_BYTES

Postconditions:
  S = |Log(T, ID)| + 1            -- next sequence number
  ts = leader wall clock at time of quorum commit
  Log(T, ID)' = Log(T, ID) ++ [Event{T, ID, S, ts, p}]
  Event is committed to floor(R/2) + 1 replicas before return
  (where R = replication factor, typically 3)
```

### Read

```
Read(T: EntityType, ID: EntityID, since: SequenceNo | null)
  -> ordered Stream<Event>

Preconditions:
  T is non-empty
  ID is non-empty

Let N = |Log(T, ID)| at time read begins

Postconditions:
  Returns exactly { e in Log(T, ID) | e.seq > since }
    (or all events if since = null)
  Events are returned in ascending seq order
  Stream is finite: contains exactly N - since events
  No event with seq <= N is omitted
```

### Subscribe

```
Subscribe(f: Filter) -> infinite Stream<Event>

Postconditions:
  For every Event e written and acknowledged after subscription opens:
    matches(f, e) => e is delivered at least once

  matches(ALL,            e) = true
  matches(ByType(T),      e) = (e.entity_type = T)
  matches(ByEntity(T,ID), e) = (e.entity_type = T AND e.entity_id = ID)

  For all T, ID: events for (T, ID) are delivered in ascending seq order
  Cross-entity ordering: by timestamp, not guaranteed strict
```

## Admin Operations

These are not part of the client API. They require operator credentials and must be fully audited.

### PayloadRedact

```
PayloadRedact(T: EntityType, ID: EntityID, S: SequenceNo)
  -> ()

Preconditions:
  Log(T, ID)[S] exists
  Caller has operator credentials

Postconditions:
  Log(T, ID)[S].payload = TOMBSTONE   -- fixed marker bytes, implementation-defined
  Log(T, ID)[S].seq, .timestamp unchanged
  |Log(T, ID)| unchanged
  Violation: narrows I-3 for this specific event (payload only)

Use for: accidental PII, leaked secrets. Prefer crypto-shredding proactively (see ADR-4).
```

### EntityLogDelete

```
EntityLogDelete(T: EntityType, ID: EntityID)
  -> ()

Preconditions:
  Caller has operator credentials

Postconditions:
  Log(T, ID)' = []                    -- entity log is gone
  All storage for (T, ID) is reclaimed
  Active Read or Subscribe calls for (T, ID) receive an explicit error or end-of-stream
  Violation: fully violates I-1, I-2, I-3, I-4 for this entity

WARNING: Largest blast radius of any operation. Any client caching state
derived from Log(T, ID) must be explicitly invalidated.

Use for: DDOS mitigation, catastrophic client misbehavior, bulk junk removal.
```

## Storage Model

```
Shard    = a contiguous range of (EntityType, EntityID) key space
Replica  = one node holding a full copy of one shard's data
Cluster  = set of shards covering the full key space, each with R replicas

Per shard:
  - One Raft group of R nodes
  - One leader; leader handles all writes and (by default) reads
  - Writes committed when floor(R/2) + 1 nodes confirm

Per node:
  - Segment log: fixed-size append-only files
  - Index: EntityType x EntityID -> [(seq, file_offset)]
  - Index is memory-resident; recoverable by replaying segment log
```

## Failure Model

```
Node failure:    Cluster tolerates floor((R-1)/2) failed nodes per shard
                 while preserving availability (R=3 -> 1 failure)

Durability:      Any acknowledged write survives floor((R-1)/2) simultaneous failures

Network partition:
                 Minority partition: stops accepting writes (Raft safety)
                 Majority partition: continues normally
                 Split-brain:        prevented by Raft leader election

Data loss:       Only possible if > floor((R-1)/2) replicas fail simultaneously
                 before a write is replicated to quorum (i.e., before Append returns)
```
