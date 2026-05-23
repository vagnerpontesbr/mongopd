#!/usr/bin/env bash
# ============================================================
#  mongopd.sh — MongoDB Problem & Determination
#  Equivalent to IBM Db2's db2pd diagnostic utility.
#  Mirrors db2pd flag names and diagnostic intent.
#
#  Repository : https://github.com/[user]/db2-to-mongodb
#  Version    : 1.0.0
#
#  USAGE
#    mongopd.sh -db <database> [connection] [diagnostic-flag] [modifiers]
#    mongopd.sh -help
#
#  ENVIRONMENT VARIABLE
#    MONGODB_URI   Full MongoDB URI — used when -uri and -host are not provided
#    Example:  export MONGODB_URI="mongodb+srv://dba:pass@cluster.mongodb.net"
#
#  ALIAS RECOMMENDATION
#    Add to ~/.zshrc or ~/.bashrc:
#      alias mpd='mongopd.sh'
#      export MONGODB_URI="mongodb+srv://dba:pass@cluster.mongodb.net"
#    Then use:
#      mpd -db sales -locks wait
# ============================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────
#  Constants
# ─────────────────────────────────────────────────────────────
VERSION="1.0.0"
DEFAULT_HOST="localhost:27017"
DEFAULT_SLOWMS=200
DEFAULT_SECS=0
DEFAULT_INTERVAL=5
DEFAULT_LIMIT=20

# ─────────────────────────────────────────────────────────────
#  ANSI colors — disabled when not a tty or NO_COLOR is set
# ─────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  BOLD="\033[1m"
  CYAN="\033[36m"
  YELLOW="\033[33m"
  RED="\033[31m"
  RESET="\033[0m"
else
  BOLD="" CYAN="" YELLOW="" RED="" RESET=""
fi

# ─────────────────────────────────────────────────────────────
#  State variables
# ─────────────────────────────────────────────────────────────
HOST=""
URI=""
DB_NAME=""
USERNAME=""
PASSWORD=""
AUTH_DB="admin"

FLAG_LOCKS=false
LOCKS_WAIT=false
FLAG_WLOCKS=false
FLAG_APPLICATIONS=false
FLAG_AGENTS=false
FLAG_DYNAMIC=false
FLAG_TCBSTATS=false
FLAG_TABLES=false
FLAG_INDEXES=false
FLAG_MEMPOOLS=false
FLAG_TRANSACTIONS=false
FLAG_UTILITIES=false
FLAG_REORGS=false
FLAG_HADR=false
FLAG_STAT=false
FLAG_KILL=false
FLAG_HELP=false

KILL_OPID=""
SLOWMS=$DEFAULT_SLOWMS
SECS=$DEFAULT_SECS
INTERVAL=$DEFAULT_INTERVAL
LIMIT=$DEFAULT_LIMIT
SCALE=1
SCALE_LABEL="bytes"
PROFILING_ACTION=""
COLLECTION=""
DISPATCH_COUNT=0

# ─────────────────────────────────────────────────────────────
#  Resolve connection from environment variable
#  Priority: -uri flag > MONGODB_URI env var > -host flag > default host
# ─────────────────────────────────────────────────────────────
resolve_connection() {
  if [[ -z "$URI" ]] && [[ -n "${MONGODB_URI:-}" ]]; then
    URI="${MONGODB_URI}"
  fi
}

# ─────────────────────────────────────────────────────────────
#  Output helpers
# ─────────────────────────────────────────────────────────────
print_header() {
  local title="$1"
  local ts
  ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
  printf "${BOLD}${CYAN}║  %-64s║${RESET}\n" "mongopd.sh — ${title}"
  printf "${BOLD}${CYAN}║  %-64s║${RESET}\n" "Timestamp: ${ts}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
}

print_footer() {
  echo -e "${CYAN}──────────────────────────────────────────────────────────────────${RESET}\n"
}

print_info() {
  echo -e "${YELLOW}[INFO]${RESET} $*"
}

print_warn() {
  echo -e "${YELLOW}[WARN]${RESET} $*"
}

print_error() {
  echo -e "${RED}[ERROR]${RESET} $*" >&2
}

die() {
  print_error "$*"
  exit 1
}

# ─────────────────────────────────────────────────────────────
#  Dependency check
# ─────────────────────────────────────────────────────────────
check_deps() {
  local missing=()

  if ! command -v mongosh &>/dev/null; then
    missing+=("mongosh")
  fi

  if [[ "$FLAG_STAT" == "true" ]] && ! command -v mongostat &>/dev/null; then
    missing+=("mongostat  (part of mongodb-database-tools)")
  fi

  if [[ "$FLAG_TCBSTATS" == "true" ]] && ! command -v mongotop &>/dev/null; then
    missing+=("mongotop  (part of mongodb-database-tools)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Required tools not found in PATH: ${missing[*]}"
  fi
}

# ─────────────────────────────────────────────────────────────
#  Connection builders
# ─────────────────────────────────────────────────────────────
build_mongosh_args() {
  local -a args=()

  if [[ -n "$URI" ]]; then
    # URI already embeds credentials and database — pass directly
    args+=("$URI")
  else
    args+=("--host" "${HOST:-$DEFAULT_HOST}")
  fi

  if [[ -n "$USERNAME" ]]; then
    args+=("--username" "$USERNAME")
    if [[ -n "$PASSWORD" ]]; then
      args+=("--password" "$PASSWORD")
    fi
    args+=("--authenticationDatabase" "$AUTH_DB")
  fi

  # DB_NAME is NOT passed as a positional arg here.
  # run_mongosh() prepends 'use <db>;' to every eval script instead.
  # Passing a bare db name after a URI causes mongosh to treat it as a file path.

  args+=("--quiet")
  printf '%s\n' "${args[@]}"
}

build_tool_args() {
  # Shared connection args for mongostat / mongotop
  local -a args=()

  if [[ -n "$URI" ]]; then
    args+=("--uri" "$URI")
  else
    args+=("--host" "${HOST:-$DEFAULT_HOST}")
  fi

  if [[ -n "$USERNAME" ]]; then
    args+=("--username" "$USERNAME")
    if [[ -n "$PASSWORD" ]]; then
      args+=("--password" "$PASSWORD")
    fi
    args+=("--authenticationDatabase" "$AUTH_DB")
  fi

  printf '%s\n' "${args[@]}"
}

run_mongosh() {
  local eval_script="$1"
  local db_prefix=""
  if [[ -n "$DB_NAME" ]]; then
    # 'use db;' in --eval mode causes mongosh to exit after the switch.
    # getSiblingDB reassigns db within the same eval context instead.
    db_prefix="db = db.getSiblingDB('${DB_NAME}'); "
  fi
  local -a conn_args=()
  while IFS= read -r line; do
    conn_args+=("$line")
  done < <(build_mongosh_args)
  mongosh "${conn_args[@]}" --eval "${db_prefix}${eval_script}"
}

# ─────────────────────────────────────────────────────────────
#  3.1  Locks and Lock Waiters       equiv: db2pd -locks wait
# ─────────────────────────────────────────────────────────────
cmd_locks() {
  print_header "Locks and Lock Waiters  [equiv: db2pd -locks wait]"

  if [[ "$LOCKS_WAIT" == "true" ]]; then
    print_info "Filter: waitingForLock: true"
    run_mongosh 'printjson(db.currentOp({ waitingForLock: true }));'
  else
    print_info "Filter: all lock-related active operations"
    run_mongosh 'printjson(db.currentOp({
      $or: [
        { waitingForLock: true },
        { "lockStats.Collection.acquireWaitCount": { $exists: true } }
      ]
    }));'
  fi

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.1  All lock-related operations   equiv: db2pd -wlocks
# ─────────────────────────────────────────────────────────────
cmd_wlocks() {
  print_header "All Lock-Related Operations  [equiv: db2pd -wlocks]"
  run_mongosh 'printjson(db.currentOp({
    $or: [
      { waitingForLock: true },
      { lockStats: { $exists: true } }
    ]
  }));'
  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.2  Active sessions               equiv: db2pd -applications
# ─────────────────────────────────────────────────────────────
cmd_applications() {
  print_header "Active Sessions and Connections  [equiv: db2pd -applications]"

  local filter

  if [[ $SECS -gt 0 ]]; then
    filter="{ active: true, secs_running: { \$gt: $SECS } }"
    print_info "Filter: active operations running longer than ${SECS}s"
  else
    filter="{ active: true }"
    print_info "Filter: all active operations"
  fi

  run_mongosh "printjson(db.currentOp($filter));"
  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.2  Engine agents                 equiv: db2pd -agents
# ─────────────────────────────────────────────────────────────
cmd_agents() {
  print_header "Engine Agents and Thread Activity  [equiv: db2pd -agents]"
  run_mongosh '
    var ops = db.currentOp().inprog;
    if (ops.length === 0) {
      print("  (no active operations)");
    } else {
      print("  Total threads: " + ops.length);
      ops.forEach(function(op) {
        print("  ──────────────────────────────────────────────────────────────────");
        print("  OpID      : " + op.opid);
        print("  Type      : " + op.type + "  op: " + op.op);
        print("  Namespace : " + (op.ns || "—"));
        print("  Running   : " + (op.secs_running !== undefined ? op.secs_running + "s" : "—"));
        print("  Active    : " + op.active);
        print("  Client    : " + (op.client || "—"));
        print("  User      : " + JSON.stringify(op.effectiveUsers || []));
        print("  Plan      : " + (op.planSummary || "—"));
        print("  Command   : " + JSON.stringify(op.command || {}));
      });
      print("  ──────────────────────────────────────────────────────────────────");
    }
  '
  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.6  Dynamic SQL / slow ops        equiv: db2pd -dynamic
# ─────────────────────────────────────────────────────────────
cmd_dynamic() {
  print_header "Dynamic Statements and Slow Operations  [equiv: db2pd -dynamic]"

  if [[ "$PROFILING_ACTION" == "on" ]]; then
    print_info "Enabling profiler — slowms threshold: ${SLOWMS}ms"
    run_mongosh "db.setProfilingLevel(1, { slowms: $SLOWMS }); print('Profiler enabled. slowms=${SLOWMS}');"
    echo ""
  elif [[ "$PROFILING_ACTION" == "off" ]]; then
    print_info "Disabling profiler"
    run_mongosh "db.setProfilingLevel(0); print('Profiler disabled.');"
    print_footer
    return
  fi

  print_info "Live in-flight queries:"
  run_mongosh '
    var ops = db.currentOp({ active: true }).inprog;
    if (ops.length === 0) {
      print("  (no active operations)");
    } else {
      ops.forEach(function(op) {
        print("  ──────────────────────────────────────────────────────────────────");
        print("  OpID      : " + op.opid);
        print("  Session   : " + (op.lsid ? JSON.stringify(op.lsid) : "—"));
        print("  Operation : " + op.op);
        print("  Namespace : " + (op.ns || "—"));
        print("  Running   : " + (op.secs_running || 0) + "s");
        print("  Client    : " + (op.client || "—"));
        print("  User      : " + JSON.stringify(op.effectiveUsers || []));
        print("  Query     : " + JSON.stringify(op.command || {}));
      });
      print("  ──────────────────────────────────────────────────────────────────");
    }
  '

  echo ""
  print_info "Profiler — last ${LIMIT} slow operations (threshold: ${SLOWMS}ms):"

  run_mongosh "
    var docs = db.system.profile
      .find({ millis: { \$gte: $SLOWMS } })
      .sort({ ts: -1 })
      .limit($LIMIT)
      .toArray();
    if (docs.length === 0) {
      print('  (no slow operations found above ${SLOWMS}ms threshold)');
    } else {
      docs.forEach(function(doc) {
        print('  ──────────────────────────────────────────────────────────────────');
        print('  Timestamp : ' + doc.ts);
        print('  Session   : ' + (doc.lsid ? JSON.stringify(doc.lsid) : '—'));
        print('  Operation : ' + doc.op);
        print('  Namespace : ' + doc.ns);
        print('  User      : ' + (doc.user || '—'));
        print('  Client    : ' + (doc.client || '—'));
        print('  Duration  : ' + doc.millis + ' ms');
        print('  Examined  : ' + (doc.docsExamined || 0) + ' docs  returned: ' + (doc.nreturned || 0));
        print('  Plan      : ' + (doc.planSummary || '—'));
        print('  Query     : ' + JSON.stringify(doc.command || {}));
      });
      print('  ──────────────────────────────────────────────────────────────────');
    }
  "

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.4  Per-object read/write pressure  equiv: db2pd -tcbstats
# ─────────────────────────────────────────────────────────────
cmd_tcbstats() {
  print_header "Per-Collection Read/Write Pressure  [equiv: db2pd -tcbstats]"
  print_info "Running mongotop — interval: ${INTERVAL}s  (Ctrl+C to stop)"
  print_footer

  local -a args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(build_tool_args)
  mongotop "${args[@]}" "$INTERVAL"
}

# ─────────────────────────────────────────────────────────────
#  3.5  Collection footprint          equiv: db2pd -tables
# ─────────────────────────────────────────────────────────────
cmd_tables() {
  print_header "Collection Footprint and Object Stats  [equiv: db2pd -tables]"

  if [[ -n "$COLLECTION" ]]; then
    print_info "Collection: ${DB_NAME}.${COLLECTION}   scale: ${SCALE_LABEL}"
    run_mongosh "
      var s          = db.getCollection('${COLLECTION}').stats({ scale: ${SCALE} });
      var unit       = '${SCALE_LABEL}';
      var sc         = ${SCALE};
      var ratio      = s.size > 0 ? (s.storageSize / s.size).toFixed(2) : 'N/A';

      print('  ── Collection ─────────────────────────────────────────────────────────');
      print('  Namespace   : ' + s.ns);
      print('  Documents   : ' + s.count);
      print('  Avg doc size: ' + s.avgObjSize + ' bytes');
      print('  Data size   : ' + s.size.toFixed(4) + ' ' + unit);
      print('  Storage size: ' + s.storageSize.toFixed(4) + ' ' + unit + '  (compression ratio: ' + ratio + ')');
      print('  Indexes     : ' + s.nindexes);
      print('  Index size  : ' + s.totalIndexSize.toFixed(4) + ' ' + unit);
      print('  Total size  : ' + s.totalSize.toFixed(4) + ' ' + unit);
      print('');
      print('  ── Recommendations ────────────────────────────────────────────────────');
      var recs = [];
      if (s.nindexes <= 1)
        recs.push('  [INFO] Only _id index present. Add indexes for fields used in queries.');
      if (s.size > 0 && s.totalIndexSize > s.size)
        recs.push('  [WARN] Index size (' + s.totalIndexSize.toFixed(4) + ' ' + unit + ') exceeds data size (' + s.size.toFixed(4) + ' ' + unit + ').\n         Action: review unused indexes with db.collection.aggregate([{\$indexStats:{}}])');
      if (s.avgObjSize > 524288)
        recs.push('  [INFO] Avg document > 512KB. Consider schema review to avoid large-document overhead.');
      if (recs.length === 0) recs.push('  [OK] No anomalies detected.');
      recs.forEach(function(r) { print(r); });
    "
  else
    [[ -z "$DB_NAME" ]] && die "-tables without a collection requires -db <database>"
    print_info "All collections in database: ${DB_NAME}   scale: ${SCALE_LABEL}"
    run_mongosh "
      var unit  = '${SCALE_LABEL}';
      var sc    = ${SCALE};
      var names = db.getCollectionNames();
      var totDocs = 0, totData = 0, totStorage = 0, totIdx = 0, totTotal = 0;
      var rows  = [];
      var recs  = [];

      names.forEach(function(name) {
        var s     = db.getCollection(name).stats({ scale: sc });
        var ratio = s.size > 0 ? (s.storageSize / s.size).toFixed(1) : 'N/A';
        totDocs    += s.count;
        totData    += s.size;
        totStorage += s.storageSize;
        totIdx     += s.totalIndexSize;
        totTotal   += s.totalSize;
        rows.push({ name: name, docs: s.count, avg: s.avgObjSize,
                    data: s.size, store: s.storageSize, ratio: ratio,
                    nidx: s.nindexes, idxsz: s.totalIndexSize, total: s.totalSize });
        if (s.nindexes <= 1)
          recs.push('  [INFO] ' + name + ': only _id index. Add indexes for queried fields.');
        if (s.size > 0 && s.totalIndexSize > s.size)
          recs.push('  [WARN] ' + name + ': index size > data size. Review unused indexes.');
        if (s.avgObjSize > 524288)
          recs.push('  [INFO] ' + name + ': avg doc > 512KB. Consider schema review.');
      });

      function lp(v, n) { return String(v).padEnd(n); }
      function rp(v, n) { return String(v).padStart(n); }

      var sep = '  ' + '\u2500'.repeat(107);
      var hdr = '  ' + lp('Collection', 24) +
                rp('Docs', 10) + rp('Avg(bytes)', 12) +
                rp('Data(' + unit + ')', 12) + rp('Store(' + unit + ')', 12) +
                rp('Ratio', 8) + rp('Idx', 5) +
                rp('Idx(' + unit + ')', 12) + rp('Total(' + unit + ')', 12);

      print(sep);
      print(hdr);
      print(sep);
      rows.forEach(function(r) {
        print('  ' + lp(r.name, 24) +
              rp(r.docs, 10) + rp(r.avg, 12) +
              rp(r.data.toFixed(4), 12) + rp(r.store.toFixed(4), 12) +
              rp(r.ratio, 8) + rp(r.nidx, 5) +
              rp(r.idxsz.toFixed(4), 12) + rp(r.total.toFixed(4), 12));
      });
      print(sep);
      print('  ' + lp('TOTAL (' + names.length + ' collections)', 24) +
            rp(totDocs, 10) + rp('\u2014', 12) +
            rp(totData.toFixed(4), 12) + rp(totStorage.toFixed(4), 12) +
            rp('\u2014', 8) + rp('\u2014', 5) +
            rp(totIdx.toFixed(4), 12) + rp(totTotal.toFixed(4), 12));
      print(sep);
      print('');
      print('  \u2500\u2500 Recommendations \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      if (recs.length === 0) recs.push('  [OK] No anomalies detected.');
      recs.forEach(function(r) { print(r); });
    "
  fi

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.5  Index footprint               equiv: db2pd -indexes
# ─────────────────────────────────────────────────────────────
cmd_indexes() {
  print_header "Index Footprint and Storage  [equiv: db2pd -indexes]"

  if [[ -n "$COLLECTION" ]]; then
    print_info "Collection: ${DB_NAME}.${COLLECTION}   scale: ${SCALE_LABEL}"
    run_mongosh "
      var s = db.getCollection('${COLLECTION}').stats({ scale: $SCALE, indexDetails: true });
      print('Index count        : ' + s.nindexes);
      print('Total index size   : ' + s.totalIndexSize + ' ${SCALE_LABEL}');
      print('');
      printjson(s.indexSizes);
    "
  else
    [[ -z "$DB_NAME" ]] && die "-indexes without a collection name requires -db <database>"
    print_info "All collections in database: ${DB_NAME}   scale: ${SCALE_LABEL}"
    run_mongosh "
      db.getCollectionNames().forEach(function(name) {
        var s = db.getCollection(name).stats({ scale: $SCALE });
        print('Collection: ' + name +
              '  indexes: ' + s.nindexes +
              '  totalIndexSize: ' + s.totalIndexSize + ' ${SCALE_LABEL}');
      });
    "
  fi

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.8  Memory and cache pressure     equiv: db2pd -mempools
# ─────────────────────────────────────────────────────────────
cmd_mempools() {
  print_header "Memory Pools and WiredTiger Cache Pressure  [equiv: db2pd -mempools]"

  run_mongosh '
    var ss    = db.serverStatus();
    var cache = ss.wiredTiger.cache;
    var ct    = ss.wiredTiger.concurrentTransactions;
    var mem   = ss.mem || {};

    var max       = cache["maximum bytes configured"];
    var cur       = cache["bytes currently in the cache"];
    var dirty     = cache["tracked dirty bytes in the cache"];
    var cacheUsed = (cur   / max * 100).toFixed(1);
    var dirtyPct  = (dirty / max * 100).toFixed(1);

    var appEvictions = cache["pages evicted by application threads"] || 0;
    var appReadDisk  = cache["application threads page read from disk to cache count"] || 0;
    var appWriteDisk = cache["application threads page write from cache to disk count"] || 0;

    print("  ── Cache Sizing ───────────────────────────────────────────────────");
    print("  Configured        : " + (max / 1024 / 1024 / 1024).toFixed(3) + " GB");
    print("  In cache          : " + (cur / 1024 / 1024).toFixed(2) + " MB  (" + cacheUsed + "%)");
    print("  Dirty             : " + (dirty / 1024 / 1024).toFixed(2) + " MB  (" + dirtyPct + "%)");

    print("  ── I/O Pressure ───────────────────────────────────────────────────");
    print("  Pages read into cache     : " + cache["pages read into cache"]);
    print("  Pages written from cache  : " + cache["pages written from cache"]);
    print("  App threads reading disk  : " + appReadDisk);
    print("  App threads writing disk  : " + appWriteDisk);

    print("  ── Eviction Pressure ──────────────────────────────────────────────");
    print("  Evicted by app threads    : " + appEvictions + (appEvictions > 0 ? "  << CRITICAL" : "  OK"));
    print("  Unmodified pages evicted  : " + (cache["unmodified pages evicted"] || 0));
    print("  Modified pages evicted    : " + (cache["modified pages evicted"] || 0));
    print("  Eviction worker evictions : " + (cache["eviction worker thread evicted pages"] || 0));
    print("  Eviction server rounds    : " + (cache["eviction server rounds"] || 0));

    print("  ── Storage Engine Tickets (read / write slots) ────────────────");
    if (ct) {
      print("  Read  tickets  in use / available / total : " +
        ct.read.out  + " / " + ct.read.available  + " / " + ct.read.totalTickets);
      print("  Write tickets  in use / available / total : " +
        ct.write.out + " / " + ct.write.available + " / " + ct.write.totalTickets);
    } else {
      print("  Ticket info not available.");
    }

    print("  ── Process Memory ──────────────────────────────────────────────────");
    print("  Resident  : " + (mem.resident || "—") + " MB");
    print("  Virtual   : " + (mem.virtual  || "—") + " MB");

    print("  ── Recommendations ────────────────────────────────────────────────");
    var recs = [];
    if (appEvictions > 0) {
      recs.push("  [CRITICAL] Application threads are performing " + appEvictions +
        " evictions. The working set does not fit in cache." +
        "\n             Action: increase storage.wiredTiger.engineConfig.cacheSizeGB" +
        "\n             or reduce the working set by archiving cold data.");
    }
    if (parseFloat(cacheUsed) >= 90) {
      recs.push("  [WARN] Cache at " + cacheUsed + "% capacity. Eviction pressure is imminent." +
        "\n         Action: monitor eviction counters; consider increasing cache size.");
    } else if (parseFloat(cacheUsed) >= 80) {
      recs.push("  [INFO] Cache at " + cacheUsed + "% — healthy headroom is narrowing. Watch dirty% trend.");
    }
    if (parseFloat(dirtyPct) >= 10) {
      recs.push("  [WARN] Dirty pages at " + dirtyPct + "%. Storage subsystem is not flushing fast enough." +
        "\n         Action: check disk write throughput and I/O latency. Verify no I/O bottleneck.");
    } else if (parseFloat(dirtyPct) >= 5) {
      recs.push("  [INFO] Dirty pages at " + dirtyPct + "%. Elevated but not critical. Monitor trend.");
    }
    if (appReadDisk > 500) {
      recs.push("  [INFO] High app-thread disk reads (" + appReadDisk + ")." +
        "\n         The read working set is larger than cache. Consider increasing cache" +
        "\n         or adding indexes to reduce the documents read per query.");
    }
    if (ct && ct.write.available === 0) {
      recs.push("  [CRITICAL] Write ticket pool exhausted (0 available). Writers are queuing." +
        "\n             Action: identify and resolve the blocking write workload immediately.");
    }
    if (ct && ct.read.available === 0) {
      recs.push("  [CRITICAL] Read ticket pool exhausted (0 available). Readers are queuing." +
        "\n             Action: identify slow scans using -dynamic and add missing indexes.");
    }
    if (recs.length === 0) {
      recs.push("  [OK] Cache pressure is within normal bounds. No action required.");
    }
    recs.forEach(function(r) { print(r); });
  '

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.9  Transactions                  equiv: db2pd -transactions
# ─────────────────────────────────────────────────────────────
cmd_transactions() {
  print_header "In-Flight Transactions  [equiv: db2pd -transactions]"

  local secs_threshold=0
  if [[ $SECS -gt 0 ]]; then
    secs_threshold=$SECS
    print_info "Filter: transactions running longer than ${SECS}s"
  else
    print_info "Filter: all active operations"
  fi

  run_mongosh "printjson(db.currentOp({ active: true, secs_running: { \$gt: $secs_threshold } }));"

  echo ""
  print_info "Aggregate transaction counters:"
  run_mongosh 'printjson(db.serverStatus().transactions);'

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.7  Utilities / long-running ops  equiv: db2pd -utilities
# ─────────────────────────────────────────────────────────────
cmd_utilities() {
  local secs_threshold=30
  if [[ $SECS -gt 0 ]]; then
    secs_threshold=$SECS
  fi

  print_header "Active Utilities and Long-Running Tasks  [equiv: db2pd -utilities]"
  print_info "Operations running longer than ${secs_threshold}s:"

  run_mongosh "printjson(db.currentOp({ active: true, secs_running: { \$gt: $secs_threshold } }));"

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.7  Background data movement      equiv: db2pd -reorgs
# ─────────────────────────────────────────────────────────────
cmd_reorgs() {
  print_header "Background Builds and Data Movement  [equiv: db2pd -reorgs]"

  run_mongosh '
    printjson(db.currentOp({
      $or: [
        { "command.createIndexes": { $exists: true } },
        { "msg": /Index Build/i },
        { "msg": /compact/i },
        { "msg": /migration/i }
      ]
    }));
  '

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.10  Replica set health           equiv: db2pd -hadr
# ─────────────────────────────────────────────────────────────
cmd_hadr() {
  print_header "Replica Set Health and Replication State  [equiv: db2pd -hadr]"

  run_mongosh '
    var st  = rs.status();
    var cfg = rs.conf();
    var now = new Date();

    print("  ── Replica Set Overview ────────────────────────────────────────────");
    print("  Set name    : " + st.set);
    print("  My state    : " + st.myState + "  (1=PRIMARY 2=SECONDARY 6=UNKNOWN 8=DOWN)");
    print("  Members     : " + st.members.length);

    var unhealthy = [];
    var lagging   = [];
    var primary   = null;

    st.members.forEach(function(m) {
      if (m.stateStr === "PRIMARY") primary = m;
    });

    print("");
    print("  ── Members ─────────────────────────────────────────────────────────");
    st.members.forEach(function(m) {
      var lagSec = 0;
      if (primary && m.stateStr === "SECONDARY" && primary.optimeDate && m.optimeDate) {
        lagSec = Math.round((primary.optimeDate - m.optimeDate) / 1000);
      }

      var healthLabel = m.health === 1 ? "OK" : "DOWN  << CRITICAL";
      if (m.health !== 1) unhealthy.push(m.name);
      if (lagSec > 10)    lagging.push({ name: m.name, lag: lagSec });

      print("  ──────────────────────────────────────────────────────────────────");
      print("  Member      : " + m.name);
      print("  State       : " + m.stateStr);
      print("  Health      : " + healthLabel);
      print("  Votes       : " + (m.votes !== undefined ? m.votes : "—"));
      print("  Priority    : " + (m.priority !== undefined ? m.priority : "—") +
            (m.priority === 0 ? "  (non-electable)" : ""));
      if (m.stateStr === "PRIMARY") {
        print("  Optime      : " + (m.optimeDate || "—"));
        print("  Uptime      : " + Math.round((m.uptime || 0) / 3600) + "h");
      } else if (m.stateStr === "SECONDARY") {
        print("  Optime      : " + (m.optimeDate || "—"));
        print("  Repl lag    : " + lagSec + "s" +
              (lagSec > 30 ? "  << WARNING" : lagSec > 10 ? "  << ELEVATED" : "  OK"));
        print("  Last hbeat  : " + (m.lastHeartbeatMessage || "OK"));
        print("  Ping (ms)   : " + (m.pingMs !== undefined ? m.pingMs : "—"));
      } else {
        print("  Last hbeat  : " + (m.lastHeartbeatMessage || "—"));
      }
    });
    print("  ──────────────────────────────────────────────────────────────────");

    print("");
    print("  ── Oplog Window (data safety) ─────────────────────────────────────");
    try {
      var oplog = db.getSiblingDB("local").oplog.rs;
      var first = oplog.find().sort({ $natural:  1 }).limit(1).next();
      var last  = oplog.find().sort({ $natural: -1 }).limit(1).next();
      var windowHours = ((last.ts.t - first.ts.t) / 3600).toFixed(1);
      print("  Oplog first : " + new Date(first.ts.t * 1000));
      print("  Oplog last  : " + new Date(last.ts.t  * 1000));
      print("  Window      : " + windowHours + "h" +
            (parseFloat(windowHours) < 24 ? "  << WARNING: window < 24h" : "  OK"));
    } catch(e) {
      print("  Oplog stats : not accessible from this connection (" + e.message + ")");
    }

    print("");
    print("  ── Recommendations ────────────────────────────────────────────────");
    var recs = [];

    if (unhealthy.length > 0) {
      recs.push("  [CRITICAL] Member(s) DOWN: " + unhealthy.join(", ") +
        "\n             Action: check mongod process, network, and disk on affected host(s)." +
        "\n             With 3-member set, losing 1 more member will cause election failure.");
    }

    var primaries = st.members.filter(function(m) { return m.stateStr === "PRIMARY"; });
    if (primaries.length === 0) {
      recs.push("  [CRITICAL] No PRIMARY elected. Replica set is read-only." +
        "\n             Action: check quorum — a majority of members must be reachable.");
    } else if (primaries.length > 1) {
      recs.push("  [CRITICAL] Multiple PRIMARYs detected. Possible network partition." +
        "\n             Action: investigate network split-brain immediately.");
    }

    lagging.forEach(function(l) {
      if (l.lag > 30) {
        recs.push("  [WARN] " + l.name + " is " + l.lag + "s behind primary." +
          "\n         Causes: slow storage on secondary, heavy primary write load, or network latency." +
          "\n         Action: check secondary disk I/O and network throughput.");
      } else {
        recs.push("  [INFO] " + l.name + " lag: " + l.lag + "s — elevated but not critical. Monitor trend.");
      }
    });

    var nonVoting = st.members.filter(function(m) { return m.votes === 0; });
    if (nonVoting.length > 0 && st.members.length <= 3) {
      recs.push("  [INFO] Non-voting member(s) detected in a small set: " +
        nonVoting.map(function(m) { return m.name; }).join(", ") +
        "\n         Ensure quorum is maintained if members go offline.");
    }

    if (recs.length === 0) {
      recs.push("  [OK] All members healthy. Replication lag within normal bounds.");
    }
    recs.forEach(function(r) { print(r); });
  '

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.3  Real-time throughput          equiv: db2top
# ─────────────────────────────────────────────────────────────
cmd_stat() {
  print_header "Real-Time Throughput Monitor  [equiv: db2top / db2pd live counters]"
  print_info "Running mongostat — interval: ${INTERVAL}s  (Ctrl+C to stop)"
  print_footer

  local -a args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(build_tool_args)
  mongostat "${args[@]}" --discover "$INTERVAL"
}

# ─────────────────────────────────────────────────────────────
#  Kill operation (destructive — requires confirmation)
# ─────────────────────────────────────────────────────────────
cmd_kill() {
  print_header "Kill Operation  [equiv: db2pd agent/EDU termination]"

  if [[ -z "$KILL_OPID" ]]; then
    die "-kill requires an opid value. Use: -kill <opid>"
  fi

  print_warn "Target opid: ${KILL_OPID}"
  print_info "Current operation details:"
  run_mongosh "printjson(db.currentOp({ opid: $KILL_OPID }));"

  echo ""
  read -rp "$(echo -e "${RED}Confirm kill opid ${KILL_OPID}? [y/N]${RESET} ")" answer
  if [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
    run_mongosh "printjson(db.killOp($KILL_OPID));"
    print_info "killOp(${KILL_OPID}) sent."
  else
    print_info "Aborted. Operation not killed."
  fi

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  Help
# ─────────────────────────────────────────────────────────────
print_help() {
  cat <<EOF

${BOLD}${CYAN}mongopd.sh${RESET} ${VERSION} — MongoDB Problem & Determination
Mirrors db2pd diagnostic flags. Each flag maps to the equivalent MongoDB command.

${BOLD}USAGE${RESET}
  mongopd.sh -db <database> [connection] [diagnostic-flag] [modifiers]
  mongopd.sh -help

${BOLD}CONNECTION FLAGS${RESET}
  -host   <host:port>   Target host                  (default: localhost:27017)
  -uri    <uri>         Full MongoDB URI — overrides MONGODB_URI and -host
  -u      <username>    Username
  -p      <password>    Password
  -authdb <database>    Authentication database       (default: admin)

${BOLD}ENVIRONMENT VARIABLE${RESET}
  MONGODB_URI           Full MongoDB URI used when -uri and -host are not set
                        export MONGODB_URI="mongodb+srv://dba:pass@cluster.mongodb.net"

${BOLD}DATABASE${RESET}
  -db     <database>    Target database (required by most diagnostic flags)

${BOLD}DIAGNOSTIC FLAGS  (mirror db2pd flag names)${RESET}
  -locks [wait]         Lock waiters and blocked operations
  -wlocks               All lock-related active operations
  -applications         Active sessions and connections
  -agents               Engine agent and thread activity
  -dynamic              Active queries + profiler slow operations
  -tcbstats             Per-collection read/write pressure     (mongotop)
  -tables  [collection] Collection footprint and storage stats
  -indexes [collection] Index footprint by collection
  -mempools             WiredTiger cache and memory pressure
  -transactions         In-flight transactions and counters
  -utilities            Long-running internal operations
  -reorgs               Background index builds and data movement
  -hadr                 Replica set health and replication state
  -stat                 Real-time throughput monitor            (mongostat)

${BOLD}MODIFIERS${RESET}
  -kill    <opid>       Kill operation by opid (prompts for confirmation)
  -secs    <n>          Filter operations running longer than N seconds
  -slowms  <ms>         Profiler slow-op threshold for -dynamic  (default: 200)
  -profiling [on|off]   Enable/disable profiler (used with -dynamic)
  -limit   <n>          Limit profiler output rows               (default: 20)
  -scale   [mb|gb]      Output scale for -tables and -indexes
  -n       <seconds>    Sampling interval for -stat and -tcbstats (default: 5)
  --no-color            Disable ANSI color output

${BOLD}EXAMPLES${RESET}
  # Lock waiters
  mongopd.sh -host rs0/mdb1:27017,mdb2:27017,mdb3:27017 -db sales -locks wait

  # Active sessions running > 10s
  mongopd.sh -uri "mongodb+srv://dba:pass@cluster.mongodb.net" -db sales -applications -secs 10

  # Kill a stuck operation
  mongopd.sh -host mdb1:27017 -db sales -kill 781122

  # Real-time throughput (equivalent: db2top)
  mongopd.sh -host mdb1:27017 -stat -n 3

  # Hot collections (equivalent: db2pd -tcbstats)
  mongopd.sh -host mdb1:27017 -tcbstats -n 5

  # Collection + index size in MB (equivalent: db2pd -tables)
  mongopd.sh -host mdb1:27017 -db sales -tables orders -scale mb

  # Replica set health (equivalent: db2pd -hadr)
  mongopd.sh -uri "mongodb+srv://dba:pass@cluster.mongodb.net" -hadr

  # Enable profiler and inspect slow ops (equivalent: db2pd -dynamic)
  mongopd.sh -host mdb1:27017 -db sales -dynamic -profiling on -slowms 200

  # WiredTiger cache pressure (equivalent: db2pd -mempools)
  mongopd.sh -host mdb1:27017 -db sales -mempools

  # In-flight transactions running > 5s (equivalent: db2pd -transactions)
  mongopd.sh -host mdb1:27017 -db sales -transactions -secs 5

${BOLD}ALIAS RECOMMENDATION${RESET}
  Add to ~/.zshrc or ~/.bashrc:
    alias mpd='mongopd.sh'

  Then use:
    mpd -host mdb1:27017 -db sales -locks wait

${BOLD}REQUIREMENTS${RESET}
  mongosh         — mongodb.com/try/download/shell
  mongostat       — mongodb.com/try/download/database-tools  (for -stat)
  mongotop        — mongodb.com/try/download/database-tools  (for -tcbstats)

EOF
}

# ─────────────────────────────────────────────────────────────
#  Argument parser
# ─────────────────────────────────────────────────────────────
parse_args() {
  if [[ $# -eq 0 ]]; then
    print_help
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -help|--help|-h)
        FLAG_HELP=true; shift ;;

      --no-color)
        BOLD="" CYAN="" YELLOW="" RED="" RESET=""
        shift ;;

      -host)
        [[ -z "${2:-}" ]] && die "-host requires a value (e.g. mdb1:27017)"
        HOST="$2"; shift 2 ;;

      -uri)
        [[ -z "${2:-}" ]] && die "-uri requires a value"
        URI="$2"; shift 2 ;;

      -u)
        [[ -z "${2:-}" ]] && die "-u requires a username"
        USERNAME="$2"; shift 2 ;;

      -p)
        [[ -z "${2:-}" ]] && die "-p requires a password"
        PASSWORD="$2"; shift 2 ;;

      -authdb)
        [[ -z "${2:-}" ]] && die "-authdb requires a database name"
        AUTH_DB="$2"; shift 2 ;;

      -db)
        [[ -z "${2:-}" ]] && die "-db requires a database name"
        DB_NAME="$2"; shift 2 ;;

      -locks)
        FLAG_LOCKS=true; (( DISPATCH_COUNT++ )) || true
        if [[ "${2:-}" == "wait" ]]; then
          LOCKS_WAIT=true; shift
        fi
        shift ;;

      -wlocks)
        FLAG_WLOCKS=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -applications)
        FLAG_APPLICATIONS=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -agents)
        FLAG_AGENTS=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -dynamic)
        FLAG_DYNAMIC=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -tcbstats)
        FLAG_TCBSTATS=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -tables)
        FLAG_TABLES=true; (( DISPATCH_COUNT++ )) || true
        if [[ -n "${2:-}" ]] && [[ "${2}" != -* ]]; then
          COLLECTION="$2"; shift
        fi
        shift ;;

      -indexes)
        FLAG_INDEXES=true; (( DISPATCH_COUNT++ )) || true
        if [[ -n "${2:-}" ]] && [[ "${2}" != -* ]]; then
          COLLECTION="$2"; shift
        fi
        shift ;;

      -mempools)
        FLAG_MEMPOOLS=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -transactions)
        FLAG_TRANSACTIONS=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -utilities)
        FLAG_UTILITIES=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -reorgs)
        FLAG_REORGS=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -hadr)
        FLAG_HADR=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -stat)
        FLAG_STAT=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -kill)
        [[ -z "${2:-}" ]] && die "-kill requires an opid value"
        FLAG_KILL=true; KILL_OPID="$2"; (( DISPATCH_COUNT++ )) || true; shift 2 ;;

      -secs)
        [[ -z "${2:-}" ]] && die "-secs requires a number"
        SECS="$2"; shift 2 ;;

      -slowms)
        [[ -z "${2:-}" ]] && die "-slowms requires a value in milliseconds"
        SLOWMS="$2"; shift 2 ;;

      -profiling)
        [[ -z "${2:-}" ]] && die "-profiling requires [on|off]"
        PROFILING_ACTION="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;

      -limit)
        [[ -z "${2:-}" ]] && die "-limit requires a number"
        LIMIT="$2"; shift 2 ;;

      -scale)
        [[ -z "${2:-}" ]] && die "-scale requires [mb|gb]"
        case "$(echo "$2" | tr '[:upper:]' '[:lower:]')" in
          mb) SCALE=$(( 1024 * 1024 ));           SCALE_LABEL="MB" ;;
          gb) SCALE=$(( 1024 * 1024 * 1024 ));    SCALE_LABEL="GB" ;;
          *)  die "-scale accepts: mb or gb" ;;
        esac
        shift 2 ;;

      -n)
        [[ -z "${2:-}" ]] && die "-n requires a number (interval in seconds)"
        INTERVAL="$2"; shift 2 ;;

      *)
        die "Unknown option: $1  (use -help for usage)" ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────
#  Main dispatch
# ─────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  if [[ "$FLAG_HELP" == "true" ]]; then
    print_help
    exit 0
  fi

  resolve_connection
  check_deps

  if [[ $DISPATCH_COUNT -eq 0 ]]; then
    print_help
    exit 0
  fi

  [[ "$FLAG_LOCKS" == "true" ]]        && cmd_locks
  [[ "$FLAG_WLOCKS" == "true" ]]       && cmd_wlocks
  [[ "$FLAG_APPLICATIONS" == "true" ]] && cmd_applications
  [[ "$FLAG_AGENTS" == "true" ]]       && cmd_agents
  [[ "$FLAG_DYNAMIC" == "true" ]]      && cmd_dynamic
  [[ "$FLAG_TCBSTATS" == "true" ]]     && cmd_tcbstats
  [[ "$FLAG_TABLES" == "true" ]]       && cmd_tables
  [[ "$FLAG_INDEXES" == "true" ]]      && cmd_indexes
  [[ "$FLAG_MEMPOOLS" == "true" ]]     && cmd_mempools
  [[ "$FLAG_TRANSACTIONS" == "true" ]] && cmd_transactions
  [[ "$FLAG_UTILITIES" == "true" ]]    && cmd_utilities
  [[ "$FLAG_REORGS" == "true" ]]       && cmd_reorgs
  [[ "$FLAG_HADR" == "true" ]]         && cmd_hadr
  [[ "$FLAG_STAT" == "true" ]]         && cmd_stat
  [[ "$FLAG_KILL" == "true" ]]         && cmd_kill

  return 0
}

main "$@"
