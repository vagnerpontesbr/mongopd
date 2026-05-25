# mongopd.sh — MongoDB Problem & Determination

> Diagnostic shell utility for MongoDB, modeled after IBM Db2's `db2pd`.  
> Each flag mirrors the `db2pd` name and preserves its diagnostic intent.

---

## Disclaimer

> **This tool is NOT official MongoDB software and is NOT supported by MongoDB Technical Support.**  
> It was created to assist DB2 DBAs in their transition to MongoDB, mirroring familiar `db2pd` diagnostic patterns.
>
> **USE IN PRODUCTION WITH CAUTION.** Depending on data volume or catalog size, some diagnostics may consume additional CPU, memory, or I/O during execution. Prefer running during off-peak hours on large deployments.

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

---

## Repository structure

```
mongopd/
├── mac/
│   └── mongopd.sh        # Tested on macOS (bash 3.2 / zsh default shell)
├── linux/
│   └── mongopd.sh        # Adapted for Linux (bash, ~/.bashrc / ~/.profile)
└── README.md

source/mac/               # Native C binary (libmongoc) — no bash dependency
├── CMakeLists.txt
└── src/
    ├── main.c
    ├── args.{h,c}
    ├── connection.{h,c}
    ├── output.{h,c}
    ├── bsonutil.{h,c}
    └── cmd_*.{h,c}       # One file pair per diagnostic command
```

Both versions are functionally identical. The only difference is the shell configuration file references
in comments and help text (`~/.zshrc` on macOS, `~/.bashrc` on Linux).

---

## Build (C native binary)

A standalone binary that replaces the bash dependency entirely. Requires
[libmongoc](https://www.mongodb.com/docs/drivers/c/) (mongo-c-driver).

### macOS (homebrew)

```bash
# Install dependencies (one-time)
brew install mongo-c-driver cmake

# Configure and build
cmake -B build -S source/mac -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build build

# Verify
./build/mongopd -help
```

The binary is self-contained. Copy it to any directory in your `PATH`:

```bash
cp build/mongopd ~/bin/mongopd
```

> **Note:** The C binary and the shell scripts are interchangeable — they accept
> the same flags, connection options and modifiers.

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
| `-n <seconds>` | Sampling interval for `-stat` | `5` |
| `-lines <n>` | Log lines scanned by `-diag` | `5000` |
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

```
  ── Blocking Operations ────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 123400  (holding lock)
  Operation   : update
  Namespace   : sales.orders
  Running     : 42s
  Locks held  : {"Global":"w","Database":"w","Collection":"w"}
  Client      : 10.10.1.7:44018
  App         : inventory-service
  ──────────────────────────────────────────────────────────────────────────────────

  ── Lock Waiters ───────────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 123456  << WAITING
  Operation   : update
  Namespace   : sales.orders
  Waiting     : 18s
  Locks       : {"Global":"w","Database":"w","Collection":"w"}
  Client      : 10.10.2.15:41022
  App         : checkout-service
  ──────────────────────────────────────────────────────────────────────────────────

  Blockers: 1   Waiters: 1
```

When called with `wait` argument, only the Lock Waiters section is shown:

```
  ── Lock Waiters ─────────────────────────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 123456  << WAITING
  Operation   : update
  Namespace   : sales.orders
  Waiting     : 18s
  Locks       : {"Global":"w","Database":"w","Collection":"w"}
  Client      : 10.10.2.15:41022
  App         : checkout-service
  ──────────────────────────────────────────────────────────────────────────────────
  Total waiters: 1
```

#### Output analysis

| Field | What it means |
|---|---|
| `OpID` | Operation ID — use with `-kill` to terminate the blocker |
| `Running` / `Waiting` | Elapsed time in seconds; growing value confirms the operation is stuck |
| `<< WAITING` | This operation is blocked waiting for a lock to be released |
| `(holding lock)` | This operation holds the lock that is blocking others |
| `Namespace` | Where contention is occurring (`database.collection`) |
| `Locks held` / `Locks` | Lock modes held or requested per resource level |
| `Client` / `App` | Source of the session — use to identify the upstream service |

**Interpretation:** Match `Namespace` across blocks to identify the contention hot spot. The `(holding lock)` entry is the root cause; the `<< WAITING` entries are the victims. Terminate the holder with `-kill <opid>` if appropriate.

---

### `-wlocks` — All lock-related active operations

**db2pd equivalent:** `db2pd -db <db> -wlocks`

#### Syntax

```bash
mpd -host mdb1:27017 -db sales -wlocks
```

#### Output

```
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 123400  [holding]
  Operation   : update
  Namespace   : sales.orders
  Running     : 42s
  Locks       : {"Global":"w","Database":"w","Collection":"w"}
  Client      : 10.10.1.7:44018
  App         : inventory-service
  ──────────────────────────────────────────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 123456  [WAITING  << BLOCKED]
  Operation   : update
  Namespace   : sales.orders
  Running     : 18s
  Locks       : {"Global":"w","Database":"w","Collection":"w"}
  Wait count  : Collection {"w":1}
  Client      : 10.10.2.15:41022
  App         : checkout-service
  ──────────────────────────────────────────────────────────────────────────────────
  Total: 2 lock-related operation(s)
```

#### Output analysis

| Field | What it means |
|---|---|
| `[holding]` | This operation currently holds the lock |
| `[WAITING << BLOCKED]` | This operation is blocked waiting for a lock held by another op |
| `Locks` | Lock modes requested or held per resource level |
| `Wait count` | Times the engine had to wait to acquire this lock resource (from `lockStats`) |
| `Client` / `App` | Source of the session — helps trace back to the offending service |

**Interpretation:** Broader than `-locks wait`. Use this to see both sides: who is waiting and who is holding. Match `Namespace` across entries to find the contention hot spot. `Wait count` quantifies how often the lock was contended.

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

```
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 223301
  Operation   : query
  Namespace   : crm.customers
  Running     : 42s
  Waiting     : NO
  Client      : 10.10.5.9:50114
  App         : reporting-api
  User        : appuser@admin
  ──────────────────────────────────────────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 223302
  Operation   : update
  Namespace   : sales.orders
  Running     : 7s
  Waiting     : YES  << BLOCKED
  In txn      : YES  txnNum=14
  Client      : 10.10.1.4:55120
  App         : checkout-service
  User        : appuser@admin
  ──────────────────────────────────────────────────────────────────────────────────
  Total active: 2
```

#### Output analysis

| Field | What it means |
|---|---|
| `OpID` | Operation ID — use with `-kill` if the operation needs to be terminated |
| `Operation` | Operation class: `query`, `update`, `insert`, `delete`, `command` |
| `Namespace` | Target namespace (`database.collection`) |
| `Running` | Total elapsed time in seconds |
| `Waiting: YES << BLOCKED` | Operation is waiting for a lock |
| `In txn: YES txnNum=N` | Operation is part of a multi-document transaction |
| `User` | Authenticated user in `user@authdb` format |
| `Client` / `App` | Source of the request — critical for identifying the offending service |

**Interpretation:** `Waiting: YES << BLOCKED` combined with a growing `Running` time is a live lock wait. `In txn` alongside `Waiting` indicates a transaction is holding resources while blocked elsewhere — a common deadlock pattern. Use `-locks` to find who holds the blocking lock.

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

### `-tcbstats` — Per-collection storage, latency, and index usage

**db2pd equivalent:** `db2pd -tcbstats`

#### Syntax

```bash
# All collections in the database
mpd -host mdb1:27017 -db sales -tcbstats

# Single collection
mpd -host mdb1:27017 -db sales -tcbstats orders

# With MONGODB_URI
mpd -db sales -tcbstats
```

#### Output

```
  ──────────────────────────────────────────────────────────────────
  Collection    : sales.orders
  Documents     : 1250044
  Avg doc size  : 1476 bytes
  Storage       : 2048.00 MB  (data: 1760.98 MB  ratio: 1.16x)
  Indexes       : 4  (total: 2048.00 MB)

  ── Latency (cumulative since restart) ──────────────────────────────
  Reads         :     4821033 ops   avg     1.20 ms
  Writes        :     1129211 ops   avg     3.40 ms
  Commands      :       12033 ops   avg     0.20 ms

  ── Index Usage ─────────────────────────────────────────────────────
  _id_                            4121033 accesses
  status_region_idx               3822011 accesses
  old_region_idx                        0 accesses  << UNUSED

  [WARN] 1 unused index(es). Review with db.orders.aggregate([{$indexStats:{}}])
  ──────────────────────────────────────────────────────────────────
```

#### Output analysis

| Field | What it means |
|---|---|
| `Documents` | Current document count from `$collStats` |
| `Avg doc size` | Average document size in bytes (always reported in bytes regardless of `-scale`) |
| `Storage` | Compressed on-disk storage size with raw data size and compression ratio |
| `Indexes` | Index count and total index storage |
| `Latency — Reads/Writes/Commands` | Cumulative operation count and average latency since last `mongod` restart |
| `Index Usage` | Access count per index since last restart from `$indexStats` |
| `<< UNUSED` | Zero access count — candidate for removal |

**Interpretation:** Latency averages are cumulative since restart, not real-time. A high write average (> 10 ms) suggests write amplification or I/O pressure. The `<< UNUSED` marker identifies indexes with no recorded accesses — cross-reference with `-indexes` size to quantify the overhead before dropping.

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

#### Output (all collections — `mpd -db sales -indexes -scale mb`)

```
  ──────────────────────────────────────────────────────────────────────────────────
  Collection                      Indexes         Total (MB)     Avg/index (MB)
  ──────────────────────────────────────────────────────────────────────────────────
  orders                                4       2048.0000           512.0000
  customers                             3        768.0000           256.0000
  products                              2          8.0000             4.0000
  ──────────────────────────────────────────────────────────────────────────────────
  TOTAL (3 collections)                 9       2824.0000                  —
  ──────────────────────────────────────────────────────────────────────────────────

  ── Active Index Builds ────────────────────────────────────────────────────────────
  (none)
```

#### Output (single collection — `mpd -db sales -indexes orders -scale mb`)

```
  ── Indexes: sales.orders ────────────────────────────────────────────────
  Total indexes    : 4
  Total index size : 2048.0000 MB

  ──────────────────────────────────────────────────────────────────────────────────
  Name     : _id_
  Keys     : {"_id":1}
  Size     : 524.2880 MB
  Unique   : NO
  Sparse   : NO
  ──────────────────────────────────────────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  Name     : customerId_1_createdAt_-1
  Keys     : {"customerId":1,"createdAt":-1}
  Size     : 838.8608 MB
  Unique   : NO
  Sparse   : NO
  ──────────────────────────────────────────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  Name     : archivedAt_1
  Keys     : {"archivedAt":1}
  Size     : 265.4656 MB
  Unique   : NO
  Sparse   : NO
  TTL      : 2592000s
  ──────────────────────────────────────────────────────────────────────────────────

  ── Active Index Builds ─────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID       : 991340
  Collection : sales.orders
  Index(es)  : status_1_region_1
  Progress   : 67.3%  (8408750 / 12500443)  (~81s remaining)
  Running    : 168s
  ──────────────────────────────────────────────────────────────────────────────────
```

#### Output analysis

| Field | What it means |
|---|---| 
| `Collection` / `Indexes` / `Total` | Summary columns in all-collections view |
| `Avg/index` | Average index size per collection — a rising average may signal index bloat |
| `Name` | Index name as created |
| `Keys` | Indexed field(s) and sort directions |
| `Size` | Disk size of the index in the selected scale unit |
| `Unique` / `Sparse` | Index property flags |
| `TTL` | Expiry interval in seconds (present only for TTL indexes) |
| `Partial` | Partial filter expression (present only for partial indexes) |
| `Active Index Builds` | Any `createIndexes` currently running; includes progress % and ETA |

**Interpretation:** Use the all-collections view to identify which collections dominate index storage. In the single-collection view, `Size` per index combined with `-tcbstats` access counts can reveal indexes that are large but rarely used. `TTL` present on an index confirms automatic expiration is active.

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
  ── Latency Percentiles (cumulative since restart) ────────────────
  ──────────────────────────────────────────────────────────────
  Type               Ops       Avg       P50       P95       P99
  ──────────────────────────────────────────────────────────────
  Reads            19023   0.20ms   0.03ms   0.03ms   0.03ms
  Writes            1810   3.88ms   0.13ms   0.13ms   0.13ms
  Commands        244724   0.12ms   0.01ms   0.01ms   0.01ms
  ──────────────────────────────────────────────────────────────
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
| Latency Percentiles | Cumulative Avg/P50/P95/P99 per operation type since last `mongod` restart |

**Interpretation:** Cache used at 75–80% is normal under steady load. If `Dirty %` rises above 5–10% and stays elevated alongside queue buildup (visible in `-stat`), the storage subsystem may be unable to flush pages fast enough. `App threads reading disk` growing indicates the working set no longer fits in cache — either increase cache size or reduce the working set footprint. Write P99 > 20 ms or Read P99 > 50 ms are the key latency thresholds to watch.

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

```
  ── Active Operations ────────────────────────────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 556210
  Operation   : update
  Namespace   : sales.orders
  Running     : 12s
  In txn      : YES  txnNum=42
  Client      : 10.10.1.4:55120
  App         : checkout-service
  ──────────────────────────────────────────────────────────────────────────────────
```

#### Output — inactive sessions (idle in transaction)

```
  ── Inactive Sessions (open transaction, not executing) ──────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 556185
  Operation   : none
  Namespace   : —
  Idle        : 28s
  In txn      : YES  txnNum=41
  Client      : 10.10.1.4:55119
  App         : checkout-service
  ──────────────────────────────────────────────────────────────────────────────────
  1 inactive transaction(s) holding resources
```

#### Output — transaction counters

```
  ── Transaction Counters ─────────────────────────────────────────────────────────────
  currentActive    :       3
  currentInactive  :       1
  currentOpen      :       4
  totalCommitted   : 1882001
  totalAborted     :    1243
  totalStarted     : 1883244
  Abort rate       :   0.07%
  Write conflicts  :      12
```

#### Output — recommendations

```
  ── Recommendations ─────────────────────────────────────────────────────────────────
  [WARN] 1 inactive transaction(s) holding locks. Investigate idle connections.
```

#### Output analysis

| Field | What it means |
|---|---|
| `Active Operations` | Transactions currently executing; `In txn` confirms multi-document scope |
| `Inactive Sessions` | Transactions open but not executing — holding locks without doing work |
| `Idle` | Seconds the session has been dormant inside the transaction |
| `currentActive` | Transactions currently executing |
| `currentInactive` | Transactions open but not currently executing (idle in transaction) |
| `currentOpen` | Total open transactions (`currentActive` + `currentInactive`) |
| `totalAborted` | Cumulative aborted transactions since last restart |
| `Abort rate` | `totalAborted / totalStarted` — rising ratio signals conflict or timeout issues |
| `Write conflicts` | WiredTiger-level conflicts between concurrent transactions (`transaction conflict between concurrent transactions`) |

**Interpretation:** `currentInactive > 0` combined with inactive session blocks indicates application logic holding open transactions between operations — a common source of lock contention. `Write conflicts` rising means concurrent writes to the same documents are retrying repeatedly; review transaction scope and batch size.

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

```
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 781122
  Type        : command
  Namespace   : sales.$cmd
  Running     : 311s
  Progress    : 32.2%  (4021132 / 12500443)  (~655s remaining)
  Description : Index Build: scanning collection
  Waiting     : NO
  Client      : 10.10.1.8:44201
  App         : mongodb-shell
  ──────────────────────────────────────────────────────────────────────────────────
  Total: 1 long-running operation(s)
```

When no operations exceed the threshold:

```
  (no operations running longer than 30s)
```

#### Output analysis

| Field | What it means |
|---|---|
| `Type` | Operation type and class (e.g., `command`, `query`) |
| `Description` | Stage or command name — `Index Build: scanning collection`, `compact`, etc. |
| `Progress` | Completion percentage with done/total counts and ETA if available |
| `Running` | Total elapsed time for the task |
| `Waiting: YES << BLOCKED` | Task is queued waiting for a lock |

**Interpretation:** MongoDB index builds run in the background and are visible here. The `Progress` field gives completion percentage plus an ETA based on current rate. A long-running `createIndexes` operation does not block reads or writes in MongoDB 8.x. If `Running` is extreme and `Progress` is not advancing, check disk I/O and storage pressure with `-mempools`.

---

### `-reorgs` — Background index builds and data movement

**db2pd equivalent:** `db2pd -reorgs`

#### Syntax

```bash
mpd -host mdb1:27017 -db sales -reorgs
```

#### Output

```
  ── Background Index Builds ────────────────────────────────────────
  ──────────────────────────────────────────────────────────────────────────────────
  OpID        : 881200
  Collection  : sales.$cmd
  Index(es)   : customerId_1_createdAt_-1
  Running     : 95s
  Progress    : 12.4%  (1550000 / 12500443)  (~671s remaining)
  Phase       : Index Build: scanning collection
  Client      : 10.10.1.8:44201
  ──────────────────────────────────────────────────────────────────────────────────

  ── Compact Operations ─────────────────────────────────────────────
  (none)

  ── Data Migrations / Resharding ────────────────────────────────────
  (none)
```

#### Output analysis

| Section | Content |
|---|---|
| `Background Index Builds` | Active `createIndexes` operations; includes index name(s), progress % and ETA |
| `Compact Operations` | Active `compact` commands defragmenting collection storage |
| `Data Migrations / Resharding` | Chunk migrations (sharded clusters) and resharding operations |

| `Phase` value | Stage |
|---|---|
| `Index Build: scanning collection` | First pass — scanning existing documents |
| `Index Build: draining writes` | Draining write buffer accumulated during scan |
| `compact` | Collection compaction in progress |
| `migration` / `resharding` | Chunk migration or resharding operation |

**Interpretation:** MongoDB does not have a direct `REORG TABLE` equivalent. This flag captures the closest equivalent: index builds, compaction, and chunk migration. `Progress` includes an ETA calculated from elapsed time and completion ratio. All are safe to observe while the cluster is under load. Use `-utilities` for a broader view of all long-running internal work.

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

### `-osinfo` — Host CPU, memory, disk and I/O metrics

**db2pd equivalent:** `db2pd -osinfo`

> Requires running `mongopd.sh` directly on the host where `mongod` is running. When used against a remote cluster (Atlas or other), an advisory is displayed and the command returns gracefully.

#### Syntax

```bash
# Run on the mongod host
mpd -osinfo

# Against remote cluster — shows advisory
mpd -uri "mongodb+srv://dba:pass@cluster.mongodb.net" -osinfo
```

#### Output (local mongod found)

```
  mongod PID   : 12345
  dbpath       : /var/lib/mongodb
  logpath      : /var/log/mongodb/mongod.log
  port         : 27017

  ── Process (PID: 12345) ───────────────────────────────────────────────
  CPU%         : 4.2
  MEM%         : 31.5
  RSS (MB)     : 5120
  VSZ (MB)     : 8192

  ── System CPU ─────────────────────────────────────────────────────────
  %Cpu(s):  8.2 us,  1.4 sy,  0.0 ni, 89.5 id,  0.2 wa,  0.3 hi,  0.4 si
  Load avg (1/5/15): 0.82 0.74 0.68

  ── System Memory ──────────────────────────────────────────────────────
                total        used        free      shared  buff/cache   available
  Mem:          15882        9214        2108         218        4559        6220
  Swap:          2047           0        2047

  ── Disk (dbpath: /var/lib/mongodb) ────────────────────────────────────
  Filesystem      Size  Used Avail Use% Mounted on
  /dev/sda1       100G   42G   54G  44% /

  ── Disk I/O (iostat) ──────────────────────────────────────────────────
  Device            r/s     w/s    rkB/s    wkB/s   await  util%
  sda              12.4    48.2    312.0   1843.0     2.1   18.4

  ── Recommendations ────────────────────────────────────────────────────
  [OK] No resource anomalies detected.
```

#### Output (remote cluster)

```
  [INFO] No local mongod process found on this host.
  [INFO] -osinfo requires running mongopd.sh directly on the mongod host.
  [INFO] For remote cache metrics, use -mempools instead.
```

#### Output analysis

| Section | What it means |
|---|---|
| Process | PID-level CPU%, MEM%, RSS and VSZ for the `mongod` process |
| System CPU | Host-level CPU breakdown; `wa` (iowait) > 5% indicates storage bottleneck |
| System Memory | Available memory; low `available` + high swap = memory pressure |
| Disk (dbpath) | Filesystem usage for the data directory; > 85% is a warning threshold |
| Disk I/O | `await` (latency ms) and `util%` per device; `util% > 80%` is a warning |

**Interpretation:** Use `-osinfo` to correlate application-level latency spikes (visible in `-mempools` Latency Percentiles) with OS-level resource exhaustion. High `wa` cpu combined with high `await` on the device hosting `dbpath` is the classic I/O bottleneck fingerprint.

---

### `-diag` — Scan mongod log for critical events

**db2pd equivalent:** `db2diag`

> Requires access to the local `mongod` log file. On Linux, falls back to `journalctl -u mongod` when no log path is detected. When used against a remote cluster, an advisory is displayed.

#### Syntax

```bash
# Scan last 5000 lines (default)
mpd -diag

# Scan last 20000 lines
mpd -diag -lines 20000
```

#### Output

```
  ── Fatal / Crash events ────────────────────────────────────────────────
  (none in last 5000 lines)

  ── OOM signals ─────────────────────────────────────────────────────────
  (none in last 5000 lines)

  ── Elections (last 10) ─────────────────────────────────────────────────
  2026-05-22T14:12:01.003+0000  Becoming secondary
  2026-05-22T14:12:04.112+0000  Becoming primary
  Total election events: 2

  ── Index build failures ────────────────────────────────────────────────
  (none in last 5000 lines)

  ── Storage / Disk errors ───────────────────────────────────────────────
  (none in last 5000 lines)

  ── Restart markers ─────────────────────────────────────────────────────
  1 restart(s) detected in last 5000 lines
  2026-05-22T08:00:01.000+0000  mongod startup complete
```

#### Output analysis

| Section | Events scanned for |
|---|---|
| Fatal / Crash | Log entries with severity `"s":"F"` — engine faults |
| OOM signals | `out of memory`, `SIGKILL`, `Killed process` — Linux OOM killer activity |
| Elections | `REPL` component events with `election`, `stepDown`, `became primary/secondary` |
| Index build failures | `INDEX` component entries at ERROR or FATAL severity |
| Storage / Disk errors | `STORAGE` component warnings/errors including `ENOSPC`, `corrupt`, `checksum` |
| Restart markers | `initandlisten` context entries — each marks a `mongod` startup |

**Interpretation:** Multiple restarts in a short window are the first indicator of a crash loop. OOM signals alongside restarts confirm the Linux OOM killer terminated the process — either the WiredTiger cache ceiling needs reducing or the host needs more memory. Election events correlate with application-visible connection interruptions.

---

### `-sharding` — Sharding topology and balancer state

> Requires connecting to a `mongos` router. When connected to a replica set member or standalone, an advisory is displayed with the detected topology.

#### Syntax

```bash
# Connect to mongos
mpd -uri "mongodb://mongos1:27017" -sharding

# Against a replica set — shows advisory
mpd -uri "mongodb+srv://dba:pass@cluster.mongodb.net" -sharding
```

#### Output (connected to mongos)

```
  ── Shards ─────────────────────────────────────────────────────────────
  shard01              mdb1:27017,mdb2:27017,mdb3:27017
  shard02              mdb4:27017,mdb5:27017,mdb6:27017

  ── Balancer ───────────────────────────────────────────────────────────
  Mode              : full
  In round          : NO
  Scheduled moves   : 0

  ── Top collections by chunks (top 10) ─────────────────────────────────
  sales.orders                                            1024 chunks
  crm.customers                                            512 chunks
  analytics.events                                         256 chunks

  ── Sharded collections ────────────────────────────────────────────────
  sales.orders           key: {"customerId":1}  unique: NO
  crm.customers          key: {"region":1}      unique: NO

  ── Sharding statistics ────────────────────────────────────────────────
  Migration commits           : 4821
  Stale config errors         : 0
  Catalog cache — databases   : 4
  Catalog cache — collections : 12

  ── Recommendations ────────────────────────────────────────────────────
  [OK] Sharding state looks normal.
```

#### Output (connected to replica set)

```
  [INFO] This connection is not a mongos.
         -sharding requires connecting to a mongos router.
         Current topology: replica set (atlas-nsc3fg-shard-0)
```

#### Output analysis

| Section | What it means |
|---|---|
| Shards | All registered shards with connection strings; `[DRAINING]` marks shards being removed |
| Balancer | `full` = active; `off` = disabled; `In round: YES` = migration in progress |
| Top collections by chunks | Identifies hotspot collections with high chunk counts (skewed distribution risk) |
| Sharded collections | Shard key and uniqueness for each sharded collection |
| Sharding statistics | Cumulative migration commits and catalog cache health counters |

**Interpretation:** A high chunk count on a single collection combined with an inactive balancer (`off`) means distribution is not being rebalanced — manual chunk management or balancer re-enablement may be needed. `Stale config errors > 0` can cause `mongos` routing to retry unnecessarily; investigate router restarts or catalog cache refreshes.

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
| `db2pd -tcbstats` | `-tcbstats [collection]` | `db.collection.aggregate([{$collStats:{latencyStats:{},storageStats:{},count:{}}}])` |
| `db2pd -tables` | `-tables [collection]` | `db.collection.stats()` |
| `db2pd -indexes` | `-indexes [collection]` | `db.collection.stats()` (index section) |
| `db2pd -mempools` | `-mempools` | `db.serverStatus().wiredTiger.cache` + `opLatencies` |
| `db2pd -transactions` | `-transactions` | `db.currentOp()` + `serverStatus().transactions` |
| `db2pd -utilities` | `-utilities` | `db.currentOp({ secs_running: {$gt: 30} })` |
| `db2pd -reorgs` | `-reorgs` | `db.currentOp({ command.createIndexes... })` |
| `db2pd -hadr` | `-hadr` | `rs.status()` + `rs.printSecondaryReplicationInfo()` |
| `db2pd -osinfo` | `-osinfo` | `ps`, `top`, `df`, `iostat` (host OS — local mongod only) |
| `db2diag` | `-diag` | `tail` mongod log + journalctl (local mongod only) |
| Sharded cluster admin | `-sharding` | `listShards`, `balancerStatus`, `config.chunks` (requires mongos) |
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
| Which collection is the hottest? | `mpd -db sales -tcbstats` |
| Is there queue pressure on the engine? | `mpd -stat -n 3` |
| Are slow queries running? | `mpd -db sales -dynamic -profiling on -slowms 200` |
| Is the cache under pressure? | `mpd -db sales -mempools` |
| What are the read/write latency percentiles? | `mpd -db sales -mempools` (Latency Percentiles section) |
| How big is a collection and its indexes? | `mpd -db sales -tables orders -scale mb` |
| Is an index build in progress? | `mpd -db sales -utilities` |
| What is the replication lag? | `mpd -hadr` |
| Are there open transactions stalled? | `mpd -db sales -transactions -secs 10` |
| What are the host CPU, memory and disk stats? | `mpd -osinfo` (run on the mongod host) |
| Were there recent OOM kills or crashes? | `mpd -diag` (run on the mongod host) |
| Scan more log history | `mpd -diag -lines 20000` |
| Is the balancer running and are shards balanced? | `mpd -sharding` (requires mongos) |
