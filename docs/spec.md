# Formal Specification: Distributed Event Store

## Definitions

```
EntityType        = non-empty UTF-8 string, 1 <= len <= 128 bytes
EntityID          = non-empty UTF-8 string, 1 <= len <= 64 bytes
SequenceNo        = u64, >= 1
TimestampNs       = i64    -- nanoseconds since Unix epoch, leader wall clock
SKEW_WINDOW       = u64    -- nanoseconds; operator-configured
MAX_PAYLOAD_BYTES = 65536
SEGMENT_FILE_BYTES = 134217728
Payload           = byte sequence, 0 < len <= MAX_PAYLOAD_BYTES

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

Cursor       = SequenceCursor(seq: SequenceNo)    -- valid only with ByEntity filter
             | TimestampCursor(ts: TimestampNs)   -- valid only with ByType or ALL filter
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
  (where R = replication factor, typically 3; for odd R this equals ceil(R/2),
   i.e. a strict majority)
```

### Read

```
Read(f: Filter, since: Cursor | null)
  -> ordered Stream<Event>

Preconditions:
  f is a valid Filter
  If f = ByEntity(T, ID): T and ID are non-empty; since is SequenceCursor or null
  If f = ByType(T):        T is non-empty;          since is TimestampCursor or null
  If f = ALL:                                        since is TimestampCursor or null

Let S = the set of matching events at time read begins:
  matches(ALL,            e) = true
  matches(ByType(T),      e) = (e.entity_type = T)
  matches(ByEntity(T,ID), e) = (e.entity_type = T AND e.entity_id = ID)

Postconditions:
  If f = ByEntity(T, ID):
    Returns exactly { e in Log(T, ID) | e.seq > since }
      (or all events if since = null)
    Events returned in ascending seq order
    Stream is finite: no event with seq <= |Log(T,ID)| at read-start is omitted

  If f = ByType(T) or f = ALL:
    Returns exactly the events in S with timestamp > since - SKEW_WINDOW
      (or all matching events if since = null)
    Within each entity, events are returned in ascending seq order
    Cross-entity ordering: by timestamp, not guaranteed strict
    Stream is finite and complete as of read-start
    Clients must tolerate duplicate delivery when resuming from a cursor
```

### Subscribe

```
Subscribe(f: Filter, since: Cursor | null) -> infinite Stream<Event>

Postconditions:
  If since = null:
    For every Event e written and acknowledged after subscription opens:
      matches(f, e) => e is delivered at least once

  If since is a Cursor:
    For ByEntity: since is a SequenceNo; delivers events with seq > since,
      then transitions to live delivery with no gap.
    For ByType or ALL: since is a TimestampNs; delivers events with
      timestamp > since - SKEW_WINDOW, then transitions to live delivery.
    No event is omitted at the seam between historical and live delivery.
    Clients must tolerate duplicate delivery when resuming from a cursor.

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
  Violation: violates I-3 for all events that existed in Log(T, ID) — previously
             acknowledged writes are no longer retrievable. I-1, I-2, and I-4
             hold vacuously for an empty log.

WARNING: Largest blast radius of any operation. Any client caching state
derived from Log(T, ID) must be explicitly invalidated.

Use for: DDOS mitigation, catastrophic client misbehavior, bulk junk removal.
```

## Storage Model

```
Shard    = a contiguous range of (EntityType, EntityID) key space
Replica  = one node holding a full copy of one shard's data
Cluster  = set of shards covering the full key space, each with R replicas

SEGMENT_FILE_BYTES = 134217728   -- 128 MB per segment file
SKEW_WINDOW        = operator-configured u64 nanosecond duration; bounds clock
                     skew across shard leaders; used as rewind margin for
                     cross-entity cursor resumption (expected: low single-digit
                     seconds, i.e. ~1–5 × 10^9 ns)

Per shard:
  - One VSR group of R nodes
  - One primary; primary handles all writes and all reads
  - Writes committed when floor(R/2) + 1 nodes confirm

Per node:
  - Segment log: fixed-size append-only files of SEGMENT_FILE_BYTES, written in commit order
  - Segment metadata: per-segment (min_timestamp, max_timestamp) recorded
    at segment seal time; used to skip segments in timestamp-range scans
  - Entity index: EntityType x EntityID -> [(seq, file_offset)]
    Memory-resident; recoverable by replaying segment log
```

## Failure Model

```
Node failure:    Cluster tolerates floor((R-1)/2) failed nodes per shard
                 while preserving availability (R=3 -> 1 failure)

Durability:      Any acknowledged write survives floor((R-1)/2) simultaneous failures

Network partition:
                 Minority partition: stops accepting writes (VSR safety)
                 Majority partition: continues normally
                 Split-brain:        prevented by VSR view change protocol

Data loss:       Only possible if > floor((R-1)/2) replicas fail simultaneously
                 before a write is replicated to quorum (i.e., before Append returns)
```
