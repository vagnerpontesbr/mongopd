# mongopd.sh — MongoDB Problem & Determination

> Diagnostic shell utility for MongoDB, modeled after IBM Db2's `db2pd`.  
> Each flag mirrors the `db2pd` name and preserves its diagnostic intent.

---

## Introduction

If you have ever been an IBM Db2 or Informix DBA, you know the power of looking directly into the database memory structures without having to run heavy SQL queries. Tools like `db2pd` and `onstat` are a DBA's best friend during a crunch.

But what happens when you need to monitor a MongoDB cluster? Where do you find that raw, real-time view straight from the storage engine (WiredTiger)?

The answer isn't in a heavy web dashboard — it's in native CLI tools that will make any Db2/Informix DBA feel right at home.

I created this repository because I worked with Informix for 25 years. During that time I also learned Db2, and both shaped the way I think about database internals and operational diagnostics. `mongopd.sh` was built to help Informix and Db2 professionals carry that same muscle memory into MongoDB — translating familiar concepts rather than starting from zero.

### Concept Translation

| What you are looking for | Db2 (`db2pd`) | Informix (`onstat`) | MongoDB (CLI) |
|---|---|---|---|
| Engine status | `-db <name>` | `-d` | `db.serverStatus()` |
| Sessions / threads | `-edus` or `-applications` | `-u` | `db.currentOp()` |
| Disk / storage stats | `-iostat` | `-d` | `db.stats()` / WiredTiger |
| Locks / latches | `-wlocks` or `-latches` | `-k` | `db.currentOp()` (locks section) |

`mongopd.sh` maps each of these to a dedicated flag, so the workflow you already know translates directly to MongoDB diagnostics.

---

## Requirements

| Tool | Purpose | Download |
|---|---|---|
| `mongosh` | All diagnostic flags | [mongodb.com/try/download/shell](https://www.mongodb.com/try/download/shell) |
| `mongostat` | `-stat` flag | [mongodb.com/try/download/database-tools](https://www.mongodb.com/try/download/database-tools) |
| `mongotop` | `-tcbstats` flag | same as above |

---

## Repository structure

```
mongopd/
├── mac/
│   └── mongopd.sh        # Tested on macOS (bash 3.2 / zsh default shell)
├── linux/
│   └── mongopd.sh        # Adapted for Linux (bash, ~/.bashrc / ~/.profile)
└── README.md
```

Both versions are functionally identical. The only difference is the shell configuration file references
in comments and help text (`~/.zshrc` on macOS, `~/.bashrc` on Linux).

---

## Setup

### macOS

```bash
# 1. Place the script in your PATH
cp mac/mongopd.sh ~/bin/mongopd.sh
chmod +x ~/bin/mongopd.sh

# 2. Add to ~/.zshrc
echo 'alias mpd=mongopd.sh' >> ~/.zshrc
echo 'export MONGODB_URI="mongodb+srv://dba:pass@cluster.mongodb.net"' >> ~/.zshrc

# 3. Reload
source ~/.zshrc
```

### Linux

```bash
# 1. Place the script in your PATH
cp linux/mongopd.sh ~/bin/mongopd.sh
chmod +x ~/bin/mongopd.sh

# 2. Add to ~/.bashrc
echo 'alias mpd=mongopd.sh' >> ~/.bashrc
echo 'export MONGODB_URI="mongodb+srv://dba:pass@cluster.mongodb.net"' >> ~/.bashrc

# 3. Reload
source ~/.bashrc
```

---

## Connection priority

The script resolves the connection target in this order:

```
-uri flag  >  MONGODB_URI env var  >  -host flag  >  localhost:27017
```

| Method | Example |
|---|---|
| Environment variable | `export MONGODB_URI="mongodb+srv://dba:pass@cluster.mongodb.net"` |
| Explicit URI flag | `mpd -uri "mongodb+srv://dba:pass@cluster.mongodb.net" -db sales -hadr` |
| Host flag | `mpd -host mdb1:27017 -db sales -locks wait` |
| Username + password | `mpd -host mdb1:27017 -u dba -p pass -db sales -mempools` |

When `MONGODB_URI` is set, you can omit the connection flag entirely:

```bash
export MONGODB_URI="mongodb+srv://dba:pass@cluster.mongodb.net"
mpd -db sales -locks wait
mpd -db sales -hadr
mpd -db sales -applications -secs 10
```

---

## Global syntax

```
mongopd.sh -db <database> [connection] [diagnostic-flag] [modifiers]
```

### Connection flags

| Flag | Description | Default |
|---|---|---|
| `-host <host:port>` | Target host | `localhost:27017` |
| `-uri <uri>` | Full MongoDB URI (overrides `MONGODB_URI` and `-host`) | — |
| `-u <username>` | Username | — |
| `-p <password>` | Password | — |
| `-authdb <database>` | Authentication database | `admin` |

### Modifiers

| Flag | Description | Default |
|---|---|---|
| `-secs <n>` | Filter ops running longer than N seconds | — |
| `-slowms <ms>` | Profiler threshold for `-dynamic` | `200` |
| `-profiling [on\|off]` | Enable/disable profiler (use with `-dynamic`) | — |
| `-limit <n>` | Limit profiler rows for `-dynamic` | `20` |
| `-scale [mb\|gb]` | Output scale for `-tables` and `-indexes` | bytes |
| `-n <seconds>` | Sampling interval for `-stat` and `-tcbstats` | `5` |
| `-kill <opid>` | Kill operation by opid (prompts for confirmation) | — |
| `--no-color` | Disable ANSI color output | — |

---

## Commands

### `-locks` — Lock waiters and blocked operations

**db2pd equivalent:** `db2pd -db <db> -locks wait`

#### Syntax

```bash
# All lock-related operations
mpd -host mdb1:27017 -db sales -locks

# Only operations waiting for a lock
mpd -host mdb1:27017 -db sales -locks wait

# Using environment variable
export MONGODB_URI="mongodb+srv://dba:pass@cluster.mongodb.net"
mpd -db sales -locks wait
```

#### Output

```json
{
  "inprog": [
    {
      "opid": 123456,
      "active": true,
      "secs_running": 18,
      "op": "update",
      "ns": "sales.orders",
      "waitingForLock": true,
      "lockStats": {
        "Global": { "acquireCount": { "w": 1 } },
        "Database": { "acquireCount": { "w": 1 } },
        "Collection": {
          "acquireWaitCount": { "w": 1 },
          "timeAcquiringMicros": { "w": 17983421 }
        }
      },
      "client": "10.10.2.15:41022",
      "appName": "inventory-service"
    }
  ]
}
```

#### Output analysis

| Field | What it means |
|---|---|
| `opid` | Operation ID — use this value with `-kill` |
| `secs_running` | Elapsed time in seconds. Growing value confirms the operation is stuck |
| `waitingForLock: true` | This operation is blocked waiting for a lock to be released |
| `ns` | Namespace where contention is occurring (database.collection) |
| `lockStats.Collection.timeAcquiringMicros` | Time spent waiting for the collection-level lock in microseconds |
| `client` / `appName` | Source of the blocking session — use this to identify the upstream service |

**Interpretation:** If `waitingForLock: true` and `secs_running` is growing, the operation is in a live lock wait. Identify the holder by looking for the same `ns` with an active write (`op: "update"` or `op: "insert"`) that is NOT waiting for a lock. Terminate the holder if appropriate using `-kill <opid>`.

---

### `-wlocks` — All lock-related active operations

**db2pd equivalent:** `db2pd -db <db> -wlocks`

#### Syntax

```bash
mpd -host mdb1:27017 -db sales -wlocks
```

#### Output

```json
{
  "inprog": [
    {
      "opid": 123456,
      "active": true,
      "secs_running": 18,
      "op": "update",
      "ns": "sales.orders",
      "waitingForLock": true
    },
    {
      "opid": 123400,
      "active": true,
      "secs_running": 42,
      "op": "update",
      "ns": "sales.orders",
      "waitingForLock": false,
      "lockStats": {
        "Collection": { "acquireCount": { "w": 1 } }
      }
    }
  ]
}
```

#### Output analysis

| Scenario | Indicator |
|---|---|
| Waiter | `waitingForLock: true` |
| Holder | `waitingForLock: false` with `lockStats` and active write on the same `ns` |
| Contention point | Multiple operations on the same `ns` with write intent |

**Interpretation:** Broader than `-locks wait`. Use this to see both sides: who is waiting and who is holding. Compare `ns` across entries to find the contention hot spot.

---

### `-applications` — Active sessions and connections

**db2pd equivalent:** `db2pd -db <db> -applications`

#### Syntax

```bash
# All active operations
mpd -host mdb1:27017 -db sales -applications

# Operations running longer than 10 seconds
mpd -host mdb1:27017 -db sales -applications -secs 10

# Using MONGODB_URI
mpd -db sales -applications -secs 10
```

#### Output

```json
{
  "inprog": [
    {
      "opid": 223301,
      "active": true,
      "secs_running": 42,
      "op": "query",
      "ns": "crm.customers",
      "command": {
        "find": "customers",
        "filter": { "status": "ACTIVE" }
      },
      "planSummary": "COLLSCAN",
      "numYields": 125,
      "client": "10.10.5.9:50114",
      "appName": "reporting-api"
    }
  ]
}
```

#### Output analysis

| Field | What it means |
|---|---|
| `op` | Operation class: `query`, `update`, `insert`, `delete`, `command` |
| `ns` | Target namespace |
| `planSummary` | Access path summary. `IXSCAN` = index used. `COLLSCAN` = full scan |
| `numYields` | How many times the operation yielded execution to other operations |
| `secs_running` | Total elapsed time |
| `client` / `appName` | Source of the request — critical for identifying the offending service |

**Interpretation:** `planSummary: "COLLSCAN"` on a long-running query is the first red flag. It indicates either a missing index or a predicate that cannot use the available indexes. Use `-dynamic` with `-profiling on` to capture more detail.

---

### `-agents` — Engine agent and thread activity

**db2pd equivalent:** `db2pd -agents`

#### Syntax

```bash
mpd -host mdb1:27017 -db sales -agents
```

#### Output

```
  Total threads: 3
  ──────────────────────────────────────────────────────────────────
  OpID      : 330021
  Type      : op  op: command
  Namespace : admin.$cmd
  Running   : 0s
  Active    : true
  Client    : 127.0.0.1:52011
  User      : [{"user":"dba","db":"admin"}]
  Plan      : —
  Command   : {"serverStatus":1}
  ──────────────────────────────────────────────────────────────────
  OpID      : 330019
  Type      : op  op: query
  Namespace : sales.orders
  Running   : 2s
  Active    : true
  Client    : 10.10.1.8:44201
  User      : [{"user":"appuser","db":"admin"}]
  Plan      : IXSCAN { customerId: 1 }
  Command   : {"find":"orders","filter":{"customerId":"C-00123"}}
  ──────────────────────────────────────────────────────────────────
  OpID      : 330020
  Type      : op  op: none
  Namespace : —
  Running   : —
  Active    : false
  Client    : —
  User      : []
  Plan      : —
  Command   : {}
  ──────────────────────────────────────────────────────────────────
```

#### Output analysis

| Field | What it means |
|---|---|
| `inprog` array | Every currently executing thread, including internal operations |
| `op: "command"` | Internal or admin-level commands |
| `op: "query"` | Client-issued read operations |
| `planSummary` | Access path for query operations |

**Interpretation:** This gives you visibility into everything the engine is currently doing, equivalent to inspecting all active EDUs in Db2. Use `-applications -secs N` when you want to focus only on long-running client requests.

---

### `-dynamic` — Active queries and profiler slow operations

**db2pd equivalent:** `db2pd -db <db> -dynamic`

#### Syntax

```bash
# Enable profiler, then inspect slow ops
mpd -host mdb1:27017 -db sales -dynamic -profiling on -slowms 200

# Inspect without changing profiler state
mpd -host mdb1:27017 -db sales -dynamic

# Increase limit and lower threshold
mpd -host mdb1:27017 -db sales -dynamic -slowms 100 -limit 50

# Disable profiler when done
mpd -host mdb1:27017 -db sales -dynamic -profiling off
```

#### Output — live in-flight queries section

```
  ──────────────────────────────────────────────────────────────────
  OpID      : 445502
  Session   : {"id":{"$binary":{"base64":"abc123==","subType":"04"}}}
  Operation : query
  Namespace : sales.orders
  Running   : 3s
  Client    : 10.20.1.51:44201
  User      : [{"user":"appuser","db":"admin"}]
  Query     : {"find":"orders","filter":{"status":"OPEN","region":"LATAM"}}
  ──────────────────────────────────────────────────────────────────
```

#### Output — profiler section (system.profile)

```
  ──────────────────────────────────────────────────────────────────
  Timestamp : 2026-05-22T17:31:44.108Z
  Session   : {"id":{"$binary":{"base64":"abc123==","subType":"04"}}}
  Operation : query
  Namespace : sales.orders
  User      : appuser@admin
  Client    : 10.20.1.51
  Duration  : 942 ms
  Examined  : 182345 docs  returned: 15
  Plan      : COLLSCAN
  Query     : {"find":"orders","filter":{"status":"OPEN","region":"LATAM"}}
  ──────────────────────────────────────────────────────────────────
```

#### Output analysis

| Field | What it means |
|---|---|
| `Duration` | Total execution time in milliseconds |
| `Examined` | Documents scanned / documents returned to the client |
| `Plan` | `COLLSCAN` = full scan; `IXSCAN` = index used |
| `Query` | The full command with predicate being evaluated |
| `Running` | Seconds the in-flight operation has been active |
| `Session` | Client LSID for traceability |

**Interpretation:** The ratio `docsExamined / nreturned` is the key efficiency indicator. A ratio of 1:1 means every scanned document was returned. A ratio of 182345:15 means the engine scanned 12,000 documents for every one it returned — a missing or unusable index. `keysExamined: 0` with `COLLSCAN` confirms no index was used. The next step is `explain("executionStats")` on the query to verify and create the correct index.

---

### `-tcbstats` — Per-collection read/write pressure

**db2pd equivalent:** `db2pd -tcbstats`

#### Syntax

```bash
# Default 5-second interval
mpd -host mdb1:27017 -tcbstats

# 3-second interval
mpd -host mdb1:27017 -tcbstats -n 3

# With MONGODB_URI
mpd -tcbstats -n 5
```

#### Output

```
ns                         total    read     write    2026-05-22T14:22:10-03:00
sales.orders               145ms    25ms     120ms
sales.customers             18ms    16ms       2ms
inventory.products          82ms    80ms       2ms
admin.system.version         1ms     1ms       0ms
```

#### Output analysis

| Column | What it means |
|---|---|
| `ns` | Namespace (database.collection) |
| `total` | Total server time spent on this namespace in the interval |
| `read` | Time consumed by read operations |
| `write` | Time consumed by write operations |

**Interpretation:** This is a time-spent metric, not a row-count metric. `sales.orders` with 120ms write and 25ms read indicates a write-heavy workload. Common causes: high insert/update rate, many indexes causing write amplification, or a large document with many indexed fields. `inventory.products` with 80ms read may indicate repeated full scans or a cache-miss-heavy read path.

---

### `-tables` — Collection footprint and storage stats

**db2pd equivalent:** `db2pd -db <db> -tables`

#### Syntax

```bash
# All collections in the database
mpd -host mdb1:27017 -db sales -tables

# Specific collection
mpd -host mdb1:27017 -db sales -tables orders

# In megabytes
mpd -host mdb1:27017 -db sales -tables orders -scale mb

# In gigabytes
mpd -host mdb1:27017 -db sales -tables orders -scale gb
```

#### Output (all collections — `mpd -db sales -tables -scale mb`)

```
  ───────────────────────────────────────────────────────────────────────────────────────────────────────────
  Collection                    Docs  Avg(bytes)    Data(MB)   Store(MB)   Ratio  Idx     Idx(MB)   Total(MB)
  ───────────────────────────────────────────────────────────────────────────────────────────────────────────
  orders                     1250044        1476   1760.9839   2048.0000     1.2    4   2048.0000   4096.0000
  customers                   845221         892    713.1246    892.0000     1.3    3    768.0000   1660.0000
  products                     12400         256      3.0233      4.0000     1.3    2      8.0000     12.0000
  ───────────────────────────────────────────────────────────────────────────────────────────────────────────
  TOTAL (3 collections)      2107665           —   2477.1318   2944.0000       —    —   2824.0000   5768.0000
  ───────────────────────────────────────────────────────────────────────────────────────────────────────────

  ── Recommendations ──────────────────────────────────────────────────────
  [OK] No anomalies detected.
```

#### Output (single collection — `mpd -db sales -tables orders -scale mb`)

```
  ── Collection ─────────────────────────────────────────────────────────────
  Namespace   : sales.orders
  Documents   : 1250044
  Avg doc size: 1476 bytes
  Data size   : 1760.9839 MB
  Storage size: 2048.0000 MB  (compression ratio: 1.16)
  Indexes     : 4
  Index size  : 2048.0000 MB
  Total size  : 4096.0000 MB

  ── Recommendations ──────────────────────────────────────────────────────
  [WARN] Index size (2048.0000 MB) exceeds data size (1760.9839 MB).
         Action: review unused indexes with db.collection.aggregate([{$indexStats:{}}])
```

#### Output analysis

| Column | What it means |
|---|---|
| `Docs` | Catalog count — no scan, reads WiredTiger metadata |
| `Avg(bytes)` | Average document size, always in bytes |
| `Data(MB)` | Logical uncompressed data volume |
| `Store(MB)` | Physical allocated storage after WiredTiger compression |
| `Ratio` | Compression ratio: `Store / Data`; >1 means compressed |
| `Idx` | Number of indexes on the collection |
| `Idx(MB)` | Total index footprint on disk |
| `Total(MB)` | Storage + indexes combined |

**Interpretation:** The gap between `size` and `storageSize` reflects WiredTiger compression efficiency. A `totalIndexSize` that approaches or exceeds available RAM is a warning that the index working set may not fit in cache, increasing read latency. If `nindexes` is high relative to write throughput, evaluate whether all indexes are actively used.

---

### `-indexes` — Index footprint by collection

**db2pd equivalent:** `db2pd -db <db> -indexes`

#### Syntax

```bash
# All collections
mpd -host mdb1:27017 -db sales -indexes

# Specific collection in MB
mpd -host mdb1:27017 -db sales -indexes orders -scale mb
```

#### Output

```
Index count        : 4
Total index size   : 2048 MB

{
  "_id_": 524288000,
  "customerId_1_createdAt_-1": 838860800,
  "status_1": 419430400,
  "region_1_status_1": 268435456
}
```

#### Output analysis

| Entry | What it means |
|---|---|
| `_id_` | Default `_id` index — always present |
| `customerId_1_createdAt_-1` | Compound index on customerId ascending, createdAt descending |
| `status_1` | Single-field index on status |
| `region_1_status_1` | Compound index on region + status |

**Interpretation:** Compare each index size against its query usage (visible in `system.profile`). An index that is large but never appears in `planSummary` output is a candidate for removal. Unused indexes consume memory and slow down every write operation due to index maintenance overhead.

---

### `-mempools` — WiredTiger cache and memory pressure

**db2pd equivalent:** `db2pd -mempools`

#### Syntax

```bash
mpd -host mdb1:27017 -db sales -mempools
```

#### Output

```
  ── Cache Sizing ───────────────────────────────────────────────────
  Configured        : 16.000 GB
  In cache          : 12288.00 MB  (75.0%)
  Dirty             : 307.35 MB  (1.9%)
  ── I/O Pressure ───────────────────────────────────────────────────
  Pages read into cache     : 1845332
  Pages written from cache  : 1129211
  App threads reading disk  : 49221
  App threads writing disk  : 31811
  ── Eviction Pressure ──────────────────────────────────────────────
  Evicted by app threads    : 0  OK
  Unmodified pages evicted  : 94821
  Modified pages evicted    : 12043
  Eviction worker evictions : 88234
  Eviction server rounds    : 32184
  ── Storage Engine Tickets (read / write slots) ────────────────
  Read  tickets  in use / available / total : 3 / 125 / 128
  Write tickets  in use / available / total : 1 / 127 / 128
  ── Process Memory ──────────────────────────────────────────────────
  Resident  : 18432 MB
  Virtual   : 24576 MB
  ── Recommendations ────────────────────────────────────────────────
  [INFO] Cache at 75.0% — healthy headroom is narrowing. Watch dirty% trend.
```

#### Output analysis

| Section | What it means |
|---|---|
| Cache Sizing | Current vs configured ceiling; used% and dirty% at a glance |
| I/O Pressure | Read/write page counts; `App threads reading disk` rising signals working set overflow |
| Eviction Pressure | `Evicted by app threads > 0` = **CRITICAL**: cache is too small for the working set |
| Storage Engine Tickets | Available read/write slots; `0 available` = queuing and latency spikes |
| Process Memory | OS-level resident and virtual memory for the mongod process |

**Interpretation:** Cache used at 75–80% is normal under steady load. If `Dirty %` rises above 5–10% and stays elevated alongside queue buildup (visible in `-stat`), the storage subsystem may be unable to flush pages fast enough. `App threads reading disk` growing indicates the working set no longer fits in cache — either increase cache size or reduce the working set footprint.

---

### `-transactions` — In-flight transactions and counters

**db2pd equivalent:** `db2pd -transactions`

#### Syntax

```bash
# All active transactions
mpd -host mdb1:27017 -db sales -transactions

# Transactions running > 5 seconds
mpd -host mdb1:27017 -db sales -transactions -secs 5
```

#### Output — active operations

```json
{
  "inprog": [
    {
      "opid": 556210,
      "active": true,
      "secs_running": 12,
      "op": "update",
      "ns": "sales.orders",
      "transaction": {
        "parameters": {
          "txnNumber": 42
        }
      },
      "client": "10.10.1.4:55120",
      "appName": "checkout-service"
    }
  ]
}
```

#### Output — aggregate counters

```json
{
  "currentActive": 3,
  "currentInactive": 1,
  "currentOpen": 4,
  "totalCommitted": 1882001,
  "totalAborted": 1243,
  "totalStarted": 1883244
}
```

#### Output analysis

| Field | What it means |
|---|---|
| `currentActive` | Transactions currently executing |
| `currentInactive` | Transactions open but not currently executing (idle in transaction) |
| `currentOpen` | Total open transactions (`currentActive` + `currentInactive`) |
| `totalAborted` | Cumulative aborted transactions since last restart |
| `totalCommitted` | Cumulative committed transactions |

**Interpretation:** `currentInactive` > 0 may indicate application-side logic holding open transactions between operations. This is a common cause of lock contention. `totalAborted / totalStarted` is the abort rate — a rising ratio suggests write conflicts, timeout issues, or application logic problems. Individual long-running transactions are visible in the `inprog` section filtered by `-secs`.

---

### `-utilities` — Active utilities and long-running internal tasks

**db2pd equivalent:** `db2pd -utilities`

#### Syntax

```bash
# Default: operations running > 30 seconds
mpd -host mdb1:27017 -db sales -utilities

# Custom threshold
mpd -host mdb1:27017 -db sales -utilities -secs 60
```

#### Output

```json
{
  "inprog": [
    {
      "opid": 781122,
      "active": true,
      "secs_running": 311,
      "op": "command",
      "ns": "sales.$cmd",
      "command": {
        "createIndexes": "orders",
        "indexes": [
          {
            "key": { "customerId": 1, "createdAt": -1 },
            "name": "customerId_1_createdAt_-1"
          }
        ]
      },
      "msg": "Index Build: scanning collection",
      "progress": { "done": 4021132, "total": 12500443 }
    }
  ]
}
```

#### Output analysis

| Field | What it means |
|---|---|
| `command.createIndexes` | Confirms an active index build |
| `msg` | Textual stage of the internal task |
| `progress.done` / `progress.total` | Task advancement — estimate completion by rate |
| `secs_running` | Total elapsed time for the task |

**Interpretation:** MongoDB index builds run in the background and are visible here. `progress.done / progress.total` gives you the completion percentage. A long-running `createIndexes` operation does not block reads or writes in MongoDB 8.x (builds use a hybrid protocol). If `secs_running` is extreme and there is no progress movement, check disk I/O and storage pressure with `-mempools`.

---

### `-reorgs` — Background index builds and data movement

**db2pd equivalent:** `db2pd -reorgs`

#### Syntax

```bash
mpd -host mdb1:27017 -db sales -reorgs
```

#### Output

```json
{
  "inprog": [
    {
      "opid": 881200,
      "active": true,
      "secs_running": 95,
      "op": "command",
      "ns": "sales.$cmd",
      "msg": "Index Build: draining writes",
      "command": {
        "createIndexes": "orders"
      }
    }
  ]
}
```

#### Output analysis

| `msg` value | Stage |
|---|---|
| `Index Build: scanning collection` | First pass — scanning existing documents |
| `Index Build: draining writes` | Draining write buffer accumulated during scan |
| `compact` | Collection compaction |
| `migration` | Chunk migration (sharded cluster) |

**Interpretation:** MongoDB does not have a direct `REORG TABLE` equivalent. This flag captures the closest equivalent: index builds, compaction, and chunk migration. All are safe to observe while the cluster is under load. Use `-utilities` for a broader view of all long-running internal work.

---

### `-hadr` — Replica set health and replication state

**db2pd equivalent:** `db2pd -hadr`

#### Syntax

```bash
mpd -uri "mongodb+srv://dba:pass@cluster.mongodb.net" -hadr

# With MONGODB_URI set
mpd -hadr
```

#### Output

```
  ── Replica Set Overview ───────────────────────────────────────────────────
  Set name    : rs0
  My state    : 1  (1=PRIMARY 2=SECONDARY 6=UNKNOWN 8=DOWN)
  Members     : 3

  ── Members ────────────────────────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────
  Member      : mdb1:27017
  State       : PRIMARY
  Health      : OK
  Votes       : 1
  Priority    : 1
  Optime      : Thu May 22 2026 17:42:01 GMT+0000
  Uptime      : 720h
  ──────────────────────────────────────────────────────────────────
  Member      : mdb2:27017
  State       : SECONDARY
  Health      : OK
  Votes       : 1
  Priority    : 1
  Optime      : Thu May 22 2026 17:41:58 GMT+0000
  Repl lag    : 3s  OK
  Last hbeat  : OK
  Ping (ms)   : 1
  ──────────────────────────────────────────────────────────────────
  Member      : mdb3:27017
  State       : SECONDARY
  Health      : OK
  Votes       : 1
  Priority    : 1
  Optime      : Thu May 22 2026 17:41:56 GMT+0000
  Repl lag    : 5s  OK
  Last hbeat  : OK
  Ping (ms)   : 2
  ──────────────────────────────────────────────────────────────────

  ── Oplog Window (data safety) ─────────────────────────────────────────────
  Oplog first : Tue May 20 2026 17:42:01 GMT+0000
  Oplog last  : Thu May 22 2026 17:42:01 GMT+0000
  Window      : 48.0h  OK

  ── Recommendations ────────────────────────────────────────────────────────
  [OK] All members healthy. Replication lag within normal bounds.
```

#### Output analysis

| Field | What it means |
|---|---|
| `State` | Member role: `PRIMARY`, `SECONDARY`, `RECOVERING`, `ARBITER` |
| `Health` | `OK` = reachable and healthy; `DOWN << CRITICAL` = unreachable |
| `Repl lag` | Seconds behind the primary optime; `>> WARNING` if > 30s |
| `Ping (ms)` | Network round-trip latency to this member |
| `Oplog Window` | Time span covered by the oplog; < 24h is a warning |
| `Votes / Priority` | Election weight; `Priority: 0` = non-electable member |

**Interpretation:** Compare `Repl lag` across all secondaries. A secondary falling behind indicates possible causes: slow storage on the secondary, heavy write load on the primary, or network issues between members. Sustained lag above 30s in production warrants investigation. `State: RECOVERING` means the member is catching up and is temporarily unavailable for reads. An oplog window under 24h means a stopped secondary risks falling off the oplog and requiring a full resync.

---

### `-stat` — Real-time throughput monitor

**db2pd equivalent:** `db2top` / `db2pd` live counters

#### Syntax

```bash
# 5-second interval (default)
mpd -host mdb1:27017 -stat

# 3-second interval
mpd -host mdb1:27017 -stat -n 3

# With MONGODB_URI
mpd -stat -n 5
```

#### Output

```
insert query update delete getmore command dirty used flushes vsize   res qrw  arw  net_in net_out conn  time
    12   880     44      2      15    210  3.1% 82.4%       0 3.12G 1.85G 0|0  2|8   95k   1.2m  124  14:21:01
     8   920     51      1      18    195  3.3% 83.1%       0 3.12G 1.86G 0|0  3|9   98k   1.3m  124  14:21:06
     5   750     38      0      12    180  3.0% 82.8%       0 3.12G 1.85G 0|0  1|4   88k   1.1m  124  14:21:11
```

#### Output analysis

| Column | What it means |
|---|---|
| `insert` / `query` / `update` / `delete` | Operations per second by type |
| `getmore` | Cursor batch retrieval rate |
| `command` | Server command rate (includes internal operations) |
| `dirty` | Percentage of WiredTiger cache containing dirty (unflushed) pages |
| `used` | Percentage of WiredTiger cache currently consumed |
| `qr\|qw` | Queued readers and queued writers — the most important queue pressure indicator |
| `ar\|aw` | Active readers and active writers |
| `net_in` / `net_out` | Network traffic rate |
| `conn` | Open client connections |

**Interpretation:**  
- `qr|qw` non-zero and persistent = queue pressure. Readers or writers are waiting for engine resources. This is the MongoDB equivalent of a saturated service class.  
- `used` near 90%+ combined with `dirty` rising = cache pressure building toward potential eviction stall.  
- `query` dominant with low writes = read-heavy workload. Verify index efficiency with `-dynamic`.  
- `insert` dominant = write-heavy workload. Monitor `-tcbstats` for hot collections and `-mempools` for flush pressure.  
- `conn` growing without recovery = connection leak in the application layer. Compare against `serverStatus().connections`.

---

### `-kill` — Terminate an operation

**db2pd equivalent:** Agent / EDU termination after lock analysis

#### Syntax

```bash
# Identify the target first
mpd -host mdb1:27017 -db sales -locks wait

# Then terminate
mpd -host mdb1:27017 -db sales -kill 123456
```

#### Interaction

```
[INFO] Target opid: 123456
[INFO] Current operation details:
{
  "inprog": [
    {
      "opid": 123456,
      "active": true,
      "secs_running": 182,
      "op": "update",
      "ns": "sales.orders",
      "client": "10.10.2.15:41022",
      "appName": "inventory-service"
    }
  ]
}

Confirm kill opid 123456? [y/N] y
{ "info": "attempting to kill op", "ok": 1 }
[INFO] killOp(123456) sent.
```

#### Output analysis

| Response | What it means |
|---|---|
| `"info": "attempting to kill op"` | The kill signal was sent to the operation thread |
| `"ok": 1` | The command was accepted by the server |

**Important:** `killOp` sends an interrupt signal — it does not guarantee immediate termination. Operations at certain internal checkpoints may take a few seconds to acknowledge the interrupt. If the operation is still visible in `db.currentOp()` after 10–15 seconds, it is likely at a non-interruptible point. Verify with `-applications` after sending the kill.

---

## Combining flags

Multiple diagnostic flags can be run in a single invocation. They execute sequentially in the same connection context:

```bash
# Locks + cache pressure in one call
mpd -host mdb1:27017 -db sales -locks wait -mempools

# Sessions + transaction counters
mpd -host mdb1:27017 -db sales -applications -secs 5 -transactions

# Full diagnostic sweep
mpd -host mdb1:27017 -db sales -locks -applications -mempools -hadr
```

---

## Quick reference: db2pd → mongopd.sh

| db2pd flag | mongopd.sh flag | MongoDB command |
|---|---|---|
| `db2pd -locks wait` | `-locks wait` | `db.currentOp({ waitingForLock: true })` |
| `db2pd -wlocks` | `-wlocks` | `db.currentOp({ $or: [...] })` |
| `db2pd -applications` | `-applications` | `db.currentOp({ active: true })` |
| `db2pd -agents` | `-agents` | `db.currentOp()` |
| `db2pd -dynamic` | `-dynamic` | `db.currentOp()` + `system.profile` |
| `db2pd -tcbstats` | `-tcbstats` | `mongotop` |
| `db2pd -tables` | `-tables [collection]` | `db.collection.stats()` |
| `db2pd -indexes` | `-indexes [collection]` | `db.collection.stats()` (index section) |
| `db2pd -mempools` | `-mempools` | `db.serverStatus().wiredTiger.cache` |
| `db2pd -transactions` | `-transactions` | `db.currentOp()` + `serverStatus().transactions` |
| `db2pd -utilities` | `-utilities` | `db.currentOp({ secs_running: {$gt: 30} })` |
| `db2pd -reorgs` | `-reorgs` | `db.currentOp({ command.createIndexes... })` |
| `db2pd -hadr` | `-hadr` | `rs.status()` + `rs.printSecondaryReplicationInfo()` |
| `db2top` | `-stat` | `mongostat` |

---

## Runbook by diagnostic intent

| Goal | Command |
|---|---|
| Who is waiting on locks? | `mpd -db sales -locks wait` |
| What is blocking the lock holder? | `mpd -db sales -wlocks` |
| Which sessions are active right now? | `mpd -db sales -applications` |
| Which sessions have been running > 30s? | `mpd -db sales -applications -secs 30` |
| Kill a stuck operation | `mpd -db sales -kill <opid>` |
| Which collection is the hottest? | `mpd -tcbstats -n 5` |
| Is there queue pressure on the engine? | `mpd -stat -n 3` |
| Are slow queries running? | `mpd -db sales -dynamic -profiling on -slowms 200` |
| Is the cache under pressure? | `mpd -db sales -mempools` |
| How big is a collection and its indexes? | `mpd -db sales -tables orders -scale mb` |
| Is an index build in progress? | `mpd -db sales -utilities` |
| What is the replication lag? | `mpd -hadr` |
| Are there open transactions stalled? | `mpd -db sales -transactions -secs 10` |
