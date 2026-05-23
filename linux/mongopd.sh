#!/usr/bin/env bash
# ============================================================
#  mongopd.sh — MongoDB Problem & Determination
#  Equivalent to IBM Db2's db2pd diagnostic utility.
#  Mirrors db2pd flag names and diagnostic intent.
#
#  Platform   : Linux
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
#    Add to ~/.bashrc or ~/.profile:
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

FLAG_OSINFO=false
FLAG_DIAG=false
FLAG_SHARDING=false
LOG_LINES=5000

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
#  Local mongod detection — shared by -osinfo and -diag
#  Sets: LOCAL_MONGOD (true|false), MONGOD_PID, MONGOD_DBPATH,
#        MONGOD_LOGPATH, MONGOD_PORT
# ─────────────────────────────────────────────────────────────
detect_local_mongod() {
  LOCAL_MONGOD=false
  MONGOD_PID=""
  MONGOD_DBPATH=""
  MONGOD_LOGPATH=""
  MONGOD_PORT="27017"

  local pid
  pid=$(pgrep -x mongod 2>/dev/null | head -1 || true)
  if [[ -z "$pid" ]]; then
    return 0
  fi

  LOCAL_MONGOD=true
  MONGOD_PID="$pid"

  local proc_args
  proc_args=$(ps -p "$pid" -o args= 2>/dev/null || true)

  local dbpath logpath port cfgfile
  dbpath=$(echo "$proc_args"  | grep -oE '\-\-dbpath [^ ]+' | awk '{print $2}' | head -1)
  logpath=$(echo "$proc_args" | grep -oE '\-\-logpath [^ ]+' | awk '{print $2}' | head -1)
  port=$(echo "$proc_args"    | grep -oE '\-\-port [0-9]+' | awk '{print $2}' | head -1)
  cfgfile=$(echo "$proc_args" | grep -oE '\-\-config [^ ]+' | awk '{print $2}' | head -1)
  [[ -z "$cfgfile" ]] && cfgfile=$(echo "$proc_args" | grep -oE '\-f [^ ]+' | awk '{print $2}' | head -1)

  if [[ -n "$cfgfile" ]] && [[ -f "$cfgfile" ]]; then
    if [[ -z "$dbpath" ]]; then
      dbpath=$(grep -E '^[[:space:]]*dbPath[[:space:]]*:' "$cfgfile" | awk -F: '{print $2}' | tr -d ' "' | head -1)
    fi
    if [[ -z "$logpath" ]]; then
      logpath=$(grep -E '^[[:space:]]*path[[:space:]]*:' "$cfgfile" | awk -F: '{print $2}' | tr -d ' "' | head -1)
    fi
    if [[ -z "$port" ]]; then
      port=$(grep -E '^[[:space:]]*port[[:space:]]*:' "$cfgfile" | awk -F: '{print $2}' | tr -d ' ' | head -1)
    fi
  fi

  MONGOD_DBPATH="${dbpath:-/var/lib/mongodb}"
  MONGOD_LOGPATH="${logpath:-}"
  MONGOD_PORT="${port:-27017}"
}

# ─────────────────────────────────────────────────────────────
#  OS host resource metrics           equiv: db2pd -osinfo
# ─────────────────────────────────────────────────────────────
cmd_osinfo() {
  print_header "Host Resource Metrics  [equiv: db2pd -osinfo]"

  detect_local_mongod

  if [[ "$LOCAL_MONGOD" == "false" ]]; then
    print_info "No local mongod process found on this host."
    print_info "-osinfo requires running mongopd.sh directly on the mongod host."
    print_info "For remote cache metrics, use -mempools instead."
    print_footer
    return 0
  fi

  echo "  mongod PID   : ${MONGOD_PID}"
  echo "  dbpath       : ${MONGOD_DBPATH}"
  [[ -n "$MONGOD_LOGPATH" ]] && echo "  logpath      : ${MONGOD_LOGPATH}"
  echo "  port         : ${MONGOD_PORT}"
  echo ""

  # ── Process ─────────────────────────────────────────────────
  echo "  \u2500\u2500 Process (PID: ${MONGOD_PID}) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500"
  local pcpu pmem rss vsz
  pcpu=$(ps -p "$MONGOD_PID" -o pcpu= 2>/dev/null | tr -d ' ' || echo "N/A")
  pmem=$(ps -p "$MONGOD_PID" -o pmem= 2>/dev/null | tr -d ' ' || echo "N/A")
  rss=$(ps  -p "$MONGOD_PID" -o rss=  2>/dev/null | tr -d ' ' || echo "N/A")
  vsz=$(ps  -p "$MONGOD_PID" -o vsz=  2>/dev/null | tr -d ' ' || echo "N/A")
  echo "  CPU%         : ${pcpu}"
  echo "  MEM%         : ${pmem}"
  if [[ "$rss" =~ ^[0-9]+$ ]]; then
    echo "  RSS (MB)     : $(( rss / 1024 ))"
    echo "  VSZ (MB)     : $(( vsz / 1024 ))"
  fi

  # ── System CPU ──────────────────────────────────────────────
  echo ""
  echo "  \u2500\u2500 System CPU \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500"
  local cpu_line
  cpu_line=$(top -bn1 2>/dev/null | grep -E '^%?Cpu' | head -1 || true)
  if [[ -n "$cpu_line" ]]; then
    echo "  ${cpu_line}"
  else
    echo "  (cpu info unavailable)"
  fi
  if [[ -f /proc/loadavg ]]; then
    local loadavg
    loadavg=$(awk '{print "Load avg (1/5/15): " $1 " " $2 " " $3}' /proc/loadavg)
    echo "  ${loadavg}"
  fi

  # ── System Memory ────────────────────────────────────────────
  echo ""
  echo "  \u2500\u2500 System Memory \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500"
  if command -v free &>/dev/null; then
    free -m | while IFS= read -r line; do echo "  ${line}"; done
  else
    echo "  (free command not available)"
  fi

  # ── Disk (dbpath) ────────────────────────────────────────────
  echo ""
  echo "  \u2500\u2500 Disk (dbpath: ${MONGOD_DBPATH}) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500"
  if [[ -d "$MONGOD_DBPATH" ]]; then
    df -h "$MONGOD_DBPATH" | while IFS= read -r line; do echo "  ${line}"; done
  else
    echo "  (dbpath not accessible from this user)"
  fi

  # ── Disk I/O (iostat) ──────────────────────────────────
  echo ""
  echo "  \u2500\u2500 Disk I/O (iostat) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500"
  if command -v iostat &>/dev/null; then
    iostat -x 1 1 2>/dev/null | grep -v '^$' | while IFS= read -r line; do echo "  ${line}"; done || echo "  (no iostat data)"
  else
    echo "  (iostat not available — install sysstat for I/O metrics)"
  fi

  # ── Recommendations ──────────────────────────────────────────
  echo ""
  echo "  \u2500\u2500 Recommendations \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500"
  local recs=()

  if [[ "$pcpu" =~ ^[0-9] ]]; then
    local cpu_int
    cpu_int=$(printf "%.0f" "$pcpu" 2>/dev/null || echo 0)
    if [[ $cpu_int -ge 80 ]]; then
      recs+=("  [WARN] mongod CPU at ${pcpu}%. Check for COLLSCAN with -dynamic or lock contention with -locks.")
    fi
  fi

  if [[ -d "$MONGOD_DBPATH" ]]; then
    local disk_pct
    disk_pct=$(df "$MONGOD_DBPATH" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || echo 0)
    if [[ "$disk_pct" =~ ^[0-9]+$ ]] && [[ $disk_pct -ge 85 ]]; then
      recs+=("  [WARN] Disk at ${disk_pct}% capacity on dbpath ${MONGOD_DBPATH}. Plan storage expansion or archival.")
    fi
  fi

  if [[ ${#recs[@]} -eq 0 ]]; then
    recs+=("  [OK] No resource anomalies detected.")
  fi
  for r in "${recs[@]}"; do echo "$r"; done

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  Log event scanner                  equiv: db2diag
# ─────────────────────────────────────────────────────────────
cmd_diag() {
  print_header "Log Event Scanner  [equiv: db2diag]"

  detect_local_mongod

  if [[ "$LOCAL_MONGOD" == "false" ]]; then
    print_info "No local mongod process found on this host."
    print_info "-diag requires access to the mongod log file on the host."
    print_info "Log events (OOM, elections, disk errors) are only visible locally."
    print_footer
    return 0
  fi

  local logfile="$MONGOD_LOGPATH"
  local log_data=""

  if [[ -n "$logfile" ]] && [[ -f "$logfile" ]]; then
    print_info "Log file   : ${logfile}"
    print_info "Scan depth : last ${LOG_LINES} lines"
    log_data=$(tail -n "$LOG_LINES" "$logfile" 2>/dev/null || true)
  elif command -v journalctl &>/dev/null; then
    print_warn "Log file not found: '${logfile:-<not detected>}'. Falling back to journalctl."
    print_info "Source     : journalctl -u mongod (last 1 hour, max ${LOG_LINES} lines)"
    log_data=$(journalctl -u mongod --since "1 hour ago" --no-pager 2>/dev/null | head -n "$LOG_LINES" || true)
    if [[ -z "$log_data" ]]; then
      print_warn "journalctl returned no data for 'mongod' service."
      print_footer
      return 0
    fi
  else
    print_warn "Log file not found or not readable: '${logfile:-<not detected>}'"
    print_info "Set the path manually: export MONGOD_LOGPATH=/path/to/mongod.log"
    print_footer
    return 0
  fi

  echo ""
  _diag_sections "$log_data"

  print_footer
}

_diag_sections() {
  local log_data="$1"

  # ── Fatal / Crash events ────────────────────────────────────
  echo "  ── Fatal / Crash events ────────────────────────────────────────────"
  local fatal_lines
  fatal_lines=$(echo "$log_data" | grep '"s":"F"' 2>/dev/null || true)
  if [[ -n "$fatal_lines" ]]; then
    echo "$fatal_lines" | while IFS= read -r line; do
      local ts msg
      ts=$(echo "$line"  | grep -oE '"\\$date":"[^"]*"' | cut -d'"' -f4 | head -1)
      msg=$(echo "$line" | grep -oE '"msg":"[^"]*"'     | cut -d'"' -f4 | head -1)
      echo "  [FATAL] ${ts}  ${msg}"
    done
  else
    echo "  (none in last ${LOG_LINES} lines)"
  fi

  # ── OOM signals ─────────────────────────────────────────────
  echo ""
  echo "  ── OOM signals ─────────────────────────────────────────────────────"
  local oom_lines
  oom_lines=$(echo "$log_data" | grep -iE 'oom|out of memory|SIGKILL|Killed process' 2>/dev/null || true)
  if [[ -n "$oom_lines" ]]; then
    echo "$oom_lines" | head -20 | while IFS= read -r line; do echo "  ${line}"; done
    local oom_count
    oom_count=$(echo "$oom_lines" | wc -l | tr -d ' ')
    [[ $oom_count -gt 20 ]] && echo "  ... (${oom_count} total matches — showing first 20)"
  else
    echo "  (none in last ${LOG_LINES} lines)"
  fi

  # ── Elections ───────────────────────────────────────────────
  echo ""
  echo "  ── Elections (last 10) ─────────────────────────────────────────────"
  local election_lines
  election_lines=$(echo "$log_data" | grep '"c":"REPL"' | grep -iE 'election|stepDown|PRIMARY|SECONDARY|became primary|became secondary' 2>/dev/null || true)
  if [[ -n "$election_lines" ]]; then
    echo "$election_lines" | tail -10 | while IFS= read -r line; do
      local ts msg
      ts=$(echo "$line"  | grep -oE '"\\$date":"[^"]*"' | cut -d'"' -f4 | head -1)
      msg=$(echo "$line" | grep -oE '"msg":"[^"]*"'     | cut -d'"' -f4 | head -1)
      echo "  ${ts}  ${msg}"
    done
    local elec_count
    elec_count=$(echo "$election_lines" | wc -l | tr -d ' ')
    echo "  Total election events: ${elec_count}"
  else
    echo "  (none in last ${LOG_LINES} lines)"
  fi

  # ── Index build failures ────────────────────────────────────
  echo ""
  echo "  ── Index build failures ────────────────────────────────────────────"
  local idx_lines
  idx_lines=$(echo "$log_data" | grep '"c":"INDEX"' | grep -E '"s":"[EF]"|failed|error' 2>/dev/null || true)
  if [[ -n "$idx_lines" ]]; then
    echo "$idx_lines" | while IFS= read -r line; do
      local ts msg
      ts=$(echo "$line"  | grep -oE '"\\$date":"[^"]*"' | cut -d'"' -f4 | head -1)
      msg=$(echo "$line" | grep -oE '"msg":"[^"]*"'     | cut -d'"' -f4 | head -1)
      echo "  ${ts}  ${msg}"
    done
  else
    echo "  (none in last ${LOG_LINES} lines)"
  fi

  # ── Storage / Disk errors ───────────────────────────────────
  echo ""
  echo "  ── Storage / Disk errors ───────────────────────────────────────────"
  local disk_lines
  disk_lines=$(echo "$log_data" | grep '"c":"STORAGE"' | grep -E '"s":"[EWF]"|ENOSPC|corrupt|checksum' 2>/dev/null || true)
  if [[ -n "$disk_lines" ]]; then
    echo "$disk_lines" | head -20 | while IFS= read -r line; do
      local ts msg
      ts=$(echo "$line"  | grep -oE '"\\$date":"[^"]*"' | cut -d'"' -f4 | head -1)
      msg=$(echo "$line" | grep -oE '"msg":"[^"]*"'     | cut -d'"' -f4 | head -1)
      echo "  ${ts}  ${msg}"
    done
  else
    echo "  (none in last ${LOG_LINES} lines)"
  fi

  # ── Restart markers ─────────────────────────────────────────
  echo ""
  echo "  ── Restart markers ─────────────────────────────────────────────────"
  local restart_lines
  restart_lines=$(echo "$log_data" | grep '"ctx":"initandlisten"' | grep -iE '"msg":"[^"]*[Ss]tarting|mongod starting|start up' 2>/dev/null || true)
  local restart_count
  restart_count=$(echo "$restart_lines" | grep -c . 2>/dev/null || echo 0)
  if [[ $restart_count -gt 0 ]]; then
    echo "  ${restart_count} restart(s) detected in last ${LOG_LINES} lines"
    echo "$restart_lines" | while IFS= read -r line; do
      local ts msg
      ts=$(echo "$line"  | grep -oE '"\\$date":"[^"]*"' | cut -d'"' -f4 | head -1)
      msg=$(echo "$line" | grep -oE '"msg":"[^"]*"'     | cut -d'"' -f4 | head -1)
      echo "  ${ts}  ${msg}"
    done
  else
    echo "  (none in last ${LOG_LINES} lines)"
  fi
}

# ─────────────────────────────────────────────────────────────
#  Sharding topology                  (requires mongos)
# ─────────────────────────────────────────────────────────────
cmd_sharding() {
  print_header "Sharding Topology and Balancer State"

  run_mongosh '
    var hello = db.adminCommand({ hello: 1 });
    if (hello.msg !== "isdbgrid") {
      print("  [INFO] This connection is not a mongos.");
      print("         -sharding requires connecting to a mongos router.");
      print("         Current topology: " +
        (hello.setName ? "replica set (" + hello.setName + ")" : "standalone or unknown"));
      quit(0);
    }

    function lp(v, n) { return String(v).padEnd(n); }
    function rp(v, n) { return String(v).padStart(n); }

    // ── Shards ───────────────────────────────────────────────
    print("  \u2500\u2500 Shards \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    var shardList = db.adminCommand({ listShards: 1 });
    if (shardList.shards && shardList.shards.length > 0) {
      shardList.shards.forEach(function(s) {
        var state = (s.state === 0) ? "  [DRAINING]" : "";
        print("  " + lp(s._id, 20) + s.host + state);
      });
    } else {
      print("  (no shards found)");
    }

    // ── Balancer ─────────────────────────────────────────────
    print("");
    print("  \u2500\u2500 Balancer \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    var bal = db.adminCommand({ balancerStatus: 1 });
    var balMode  = bal.mode  || "unknown";
    var inRound  = bal.inBalancerRound ? "YES" : "NO";
    var scheduled = (bal.numScheduledChunksMoves !== undefined) ? bal.numScheduledChunksMoves : "N/A";
    print("  Mode              : " + balMode);
    print("  In round          : " + inRound);
    print("  Scheduled moves   : " + scheduled);

    // ── Top collections by chunks (top 10) ───────────────────
    print("");
    print("  \u2500\u2500 Top collections by chunks (top 10) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    try {
      var chunkAgg = db.getSiblingDB("config").chunks.aggregate([
        { $group: { _id: "$ns", count: { $sum: 1 } } },
        { $sort:  { count: -1 } },
        { $limit: 10 }
      ]).toArray();
      if (chunkAgg.length === 0) {
        print("  (no chunk data in config.chunks)");
      } else {
        chunkAgg.forEach(function(r) {
          print("  " + lp(r._id, 52) + rp(r.count, 8) + " chunks");
        });
      }
    } catch(e) {
      print("  (unable to read config.chunks: " + e.message + ")");
    }

    // ── Sharded collections ──────────────────────────────────
    print("");
    print("  \u2500\u2500 Sharded collections \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    try {
      var cols = db.getSiblingDB("config").collections
        .find({ dropped: false }, { _id: 1, key: 1, unique: 1 }).toArray();
      if (cols.length === 0) {
        print("  (none)");
      } else {
        cols.forEach(function(c) {
          var uniq = c.unique ? "YES" : "NO";
          print("  " + lp(c._id, 50) + "  key: " + JSON.stringify(c.key) + "  unique: " + uniq);
        });
      }
    } catch(e) {
      print("  (unable to read config.collections: " + e.message + ")");
    }

    // ── Sharding statistics ──────────────────────────────────
    print("");
    print("  \u2500\u2500 Sharding statistics \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    try {
      var shardStats = db.adminCommand({ serverStatus: 1 }).shardingStatistics || {};
      var cc = shardStats.catalogCache || {};
      print("  Migration commits           : " + (shardStats.countDonorMoveChunkCommitted || 0));
      print("  Stale config errors         : " + (cc.numStaleConfigErrors || 0));
      print("  Catalog cache — databases   : " + (cc.numDatabases    || "N/A"));
      print("  Catalog cache — collections : " + (cc.numCollections  || "N/A"));
    } catch(e) {
      print("  (sharding statistics unavailable: " + e.message + ")");
    }

    // ── Recommendations ──────────────────────────────────────
    print("");
    print("  \u2500\u2500 Recommendations \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    var recs = [];
    if (balMode !== "full" && balMode !== "autoMergeOnly") {
      recs.push("  [WARN] Balancer mode is \"" + balMode + "\". Chunk distribution will not be automatically balanced.");
    }
    if (inRound === "YES") {
      recs.push("  [INFO] Balancer is currently running a migration round.");
    }
    if (typeof scheduled === "number" && scheduled > 100) {
      recs.push("  [INFO] " + scheduled + " chunk moves scheduled. Active rebalancing in progress.");
    }
    if (recs.length === 0) {
      recs.push("  [OK] Sharding state looks normal.");
    }
    recs.forEach(function(r) { print(r); });
  '

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.1  Locks and Lock Waiters       equiv: db2pd -locks wait
# ─────────────────────────────────────────────────────────────
cmd_locks() {
  print_header "Locks and Lock Waiters  [equiv: db2pd -locks wait]"

  if [[ "$LOCKS_WAIT" == "true" ]]; then
    print_info "Filter: waitingForLock: true"
    run_mongosh '
      var ops = db.currentOp({ waitingForLock: true }).inprog || [];
      print("  \u2500\u2500 Lock Waiters \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
      if (ops.length === 0) {
        print("  (no lock waiters)");
      } else {
        ops.forEach(function(op) {
          print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
          print("  OpID        : " + op.opid + "  << WAITING");
          print("  Operation   : " + op.op);
          print("  Namespace   : " + (op.ns || "\u2014"));
          print("  Waiting     : " + (op.secs_running || 0) + "s");
          print("  Locks       : " + JSON.stringify(op.locks || {}));
          print("  Client      : " + (op.client || "\u2014"));
          if (op.appName) print("  App         : " + op.appName);
          print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
        });
        print("  Total waiters: " + ops.length);
      }
    '
  else
    print_info "Filter: all lock-related active operations"
    run_mongosh '
      var waiters  = db.currentOp({ waitingForLock: true }).inprog || [];
      var allOps   = db.currentOp({ active: true }).inprog || [];
      var blockers = allOps.filter(function(op) {
        return !op.waitingForLock && op.locks && Object.keys(op.locks).length > 0;
      });
      print("  \u2500\u2500 Blocking Operations \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
      if (blockers.length === 0) {
        print("  (none)");
      } else {
        blockers.forEach(function(op) {
          print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
          print("  OpID        : " + op.opid + "  (holding lock)");
          print("  Operation   : " + op.op);
          print("  Namespace   : " + (op.ns || "\u2014"));
          print("  Running     : " + (op.secs_running || 0) + "s");
          print("  Locks held  : " + JSON.stringify(op.locks || {}));
          print("  Client      : " + (op.client || "\u2014"));
          if (op.appName) print("  App         : " + op.appName);
          print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
        });
      }
      print("");
      print("  \u2500\u2500 Lock Waiters \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
      if (waiters.length === 0) {
        print("  (none)");
      } else {
        waiters.forEach(function(op) {
          print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
          print("  OpID        : " + op.opid + "  << WAITING");
          print("  Operation   : " + op.op);
          print("  Namespace   : " + (op.ns || "\u2014"));
          print("  Waiting     : " + (op.secs_running || 0) + "s");
          print("  Locks       : " + JSON.stringify(op.locks || {}));
          print("  Client      : " + (op.client || "\u2014"));
          if (op.appName) print("  App         : " + op.appName);
          print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
        });
      }
      print("");
      print("  Blockers: " + blockers.length + "   Waiters: " + waiters.length);
    '
  fi

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.1  All lock-related operations   equiv: db2pd -wlocks
# ─────────────────────────────────────────────────────────────
cmd_wlocks() {
  print_header "All Lock-Related Operations  [equiv: db2pd -wlocks]"
  run_mongosh '
    var all = db.currentOp({ active: true }).inprog || [];
    var locked = all.filter(function(op) {
      return op.waitingForLock ||
             (op.locks && Object.keys(op.locks).length > 0);
    });
    if (locked.length === 0) {
      print("  (no lock-related operations)");
    } else {
      locked.forEach(function(op) {
        var status = op.waitingForLock ? "WAITING  << BLOCKED" : "holding";
        print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
        print("  OpID        : " + op.opid + "  [" + status + "]");
        print("  Operation   : " + op.op);
        print("  Namespace   : " + (op.ns || "\u2014"));
        print("  Running     : " + (op.secs_running || 0) + "s");
        print("  Locks       : " + JSON.stringify(op.locks || {}));
        if (op.lockStats) {
          var ls = op.lockStats;
          Object.keys(ls).forEach(function(k) {
            var v = ls[k];
            if (v.acquireWaitCount && Object.keys(v.acquireWaitCount).length > 0) {
              print("  Wait count  : " + k + " " + JSON.stringify(v.acquireWaitCount));
            }
          });
        }
        print("  Client      : " + (op.client || "\u2014"));
        if (op.appName) print("  App         : " + op.appName);
        print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
      });
      print("  Total: " + locked.length + " lock-related operation(s)");
    }
  '
  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.2  Active sessions               equiv: db2pd -applications
# ─────────────────────────────────────────────────────────────
cmd_applications() {
  print_header "Active Sessions and Connections  [equiv: db2pd -applications]"

  local secs_threshold=0
  if [[ $SECS -gt 0 ]]; then
    secs_threshold=$SECS
    print_info "Filter: active operations running longer than ${SECS}s"
  else
    print_info "Filter: all active operations"
  fi

  run_mongosh "
    var ops = db.currentOp({ active: true, secs_running: { \$gt: ${secs_threshold} } }).inprog || [];
    if (ops.length === 0) {
      print('  (no active operations matching filter)');
    } else {
      ops.forEach(function(op) {
        var user = (op.effectiveUsers && op.effectiveUsers.length > 0)
          ? op.effectiveUsers[0].user + '@' + op.effectiveUsers[0].db
          : '\u2014';
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
        print('  OpID        : ' + op.opid);
        print('  Operation   : ' + op.op);
        print('  Namespace   : ' + (op.ns || '\u2014'));
        print('  Running     : ' + (op.secs_running || 0) + 's');
        print('  Waiting     : ' + (op.waitingForLock ? 'YES  << BLOCKED' : 'NO'));
        if (op.transaction) {
          var txnNum = op.transaction.parameters ? op.transaction.parameters.txnNumber : '?';
          print('  In txn      : YES  txnNum=' + txnNum);
        }
        print('  Client      : ' + (op.client || '\u2014'));
        if (op.appName) print('  App         : ' + op.appName);
        print('  User        : ' + user);
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      });
      print('  Total active: ' + ops.length);
    }
  "
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
  print_header "Per-Collection Performance Snapshot  [equiv: db2pd -tcbstats]"

  if [[ -n "$COLLECTION" ]]; then
    print_info "Collection: ${DB_NAME}.${COLLECTION}"
  else
    [[ -z "$DB_NAME" ]] && die "-tcbstats requires -db <database>"
    print_info "All collections in database: ${DB_NAME}"
  fi

  run_mongosh "
    function toLong(v) {
      if (!v) return 0;
      return (typeof v === 'object' && v.toNumber) ? v.toNumber() : Number(v);
    }
    function avgMs(ops, lat) {
      var o = toLong(ops), l = toLong(lat);
      return o > 0 ? (l / o / 1000).toFixed(2) : '0.00';
    }
    function rp(v, n) { return String(v).padStart(n); }
    function lp(v, n) { return String(v).padEnd(n); }

    function printCollection(name) {
      var cs;
      try {
        cs = db.getCollection(name).aggregate([
          { \$collStats: {
            latencyStats: { histograms: false },
            storageStats: { scale: 1048576 },
            count: {}
          }}
        ]).toArray()[0];
      } catch(e) { return; }
      if (!cs) return;

      var lat  = cs.latencyStats || {};
      var sto  = cs.storageStats || {};
      var docs = cs.count !== undefined ? toLong(cs.count) : toLong(sto.count);
      var dataMB  = sto.size           || 0;
      var storeMB = sto.storageSize    || 0;
      var ratio   = dataMB > 0 ? (storeMB / dataMB).toFixed(2) + 'x' : 'N/A';
      var nidx    = sto.nindexes       || 0;
      var idxMB   = sto.totalIndexSize || 0;
      var avgObj  = sto.avgObjSize     || 0;

      var reads = lat.reads    || {};
      var writes= lat.writes   || {};
      var cmds  = lat.commands || {};

      print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      print('  Collection    : ' + name);
      print('  Documents     : ' + docs);
      print('  Avg doc size  : ' + avgObj + ' bytes');
      print('  Storage       : ' + storeMB.toFixed(2) + ' MB  (data: ' + dataMB.toFixed(2) + ' MB  ratio: ' + ratio + ')');
      print('  Indexes       : ' + nidx + '  (total: ' + idxMB.toFixed(2) + ' MB)');
      print('');
      print('  \u2500\u2500 Latency (cumulative since restart) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      print('  Reads         : ' + rp(toLong(reads.ops), 12) + ' ops   avg ' + rp(avgMs(reads.ops, reads.latency), 8) + ' ms');
      print('  Writes        : ' + rp(toLong(writes.ops), 12) + ' ops   avg ' + rp(avgMs(writes.ops, writes.latency), 8) + ' ms');
      print('  Commands      : ' + rp(toLong(cmds.ops), 12) + ' ops   avg ' + rp(avgMs(cmds.ops, cmds.latency), 8) + ' ms');
      print('');

      var idxStats;
      try {
        idxStats = db.getCollection(name).aggregate([{ \$indexStats: {} }]).toArray();
      } catch(e) { idxStats = []; }

      var unusedCount = 0;
      print('  \u2500\u2500 Index Usage \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      if (idxStats.length === 0) {
        print('  (no index stats available)');
      } else {
        idxStats.forEach(function(ix) {
          var ops    = toLong(ix.accesses ? ix.accesses.ops : 0);
          var unused = ops === 0 ? '  << UNUSED' : '';
          if (ops === 0) unusedCount++;
          print('  ' + lp(ix.name, 30) + rp(ops, 12) + ' accesses' + unused);
        });
      }

      var recs = [];
      if (unusedCount > 0)
        recs.push('  [WARN] ' + unusedCount + ' unused index(es). Review with db.' + name + '.aggregate([{\$indexStats:{}}])');
      var wAvg = parseFloat(avgMs(writes.ops, writes.latency));
      if (wAvg > 10)
        recs.push('  [INFO] Write avg latency ' + wAvg + ' ms. Monitor for increasing trend.');
      if (nidx <= 1)
        recs.push('  [INFO] Only _id index present. Add indexes for queried fields.');
      if (recs.length > 0) {
        print('');
        recs.forEach(function(r) { print(r); });
      }
      print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      print('');
    }

    var target = '${COLLECTION}';
    if (target !== '') {
      printCollection(target);
    } else {
      var names = db.getCollectionNames();
      names.forEach(function(n) { printCollection(n); });
    }
  "

  print_footer
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
      var s       = db.getCollection('${COLLECTION}').stats({ scale: ${SCALE}, indexDetails: true });
      var idxDefs = db.getCollection('${COLLECTION}').getIndexes();
      var sizes   = s.indexSizes || {};

      print('  \u2500\u2500 Indexes: ${DB_NAME}.${COLLECTION} \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      print('  Total indexes    : ' + s.nindexes);
      print('  Total index size : ' + s.totalIndexSize.toFixed(4) + ' ${SCALE_LABEL}');
      print('');
      idxDefs.forEach(function(idx) {
        var sz = sizes[idx.name] !== undefined ? sizes[idx.name].toFixed(4) + ' ${SCALE_LABEL}' : '\u2014';
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
        print('  Name     : ' + idx.name);
        print('  Keys     : ' + JSON.stringify(idx.key));
        print('  Size     : ' + sz);
        print('  Unique   : ' + (idx.unique ? 'YES' : 'NO'));
        print('  Sparse   : ' + (idx.sparse ? 'YES' : 'NO'));
        if (idx.expireAfterSeconds !== undefined) print('  TTL      : ' + idx.expireAfterSeconds + 's');
        if (idx.partialFilterExpression) print('  Partial  : ' + JSON.stringify(idx.partialFilterExpression));
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      });

      var builds = db.currentOp({
        \$or: [
          { 'command.createIndexes': '${COLLECTION}' },
          { msg: /Index Build/i }
        ]
      }).inprog || [];
      print('');
      print('  \u2500\u2500 Active Index Builds \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      if (builds.length === 0) {
        print('  (none)');
      } else {
        builds.forEach(function(op) {
          var pct = (op.progress && op.progress.total > 0)
            ? ((op.progress.done / op.progress.total) * 100).toFixed(1) + '%  (' + op.progress.done + ' / ' + op.progress.total + ')'
            : (op.msg || '\u2014');
          print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
          print('  OpID       : ' + op.opid);
          print('  Collection : ' + (op.ns || '\u2014'));
          if (op.command && op.command.indexes) {
            var names = op.command.indexes.map(function(i) { return i.name || JSON.stringify(i.key); }).join(', ');
            print('  Index(es)  : ' + names);
          }
          print('  Progress   : ' + pct);
          print('  Running    : ' + (op.secs_running || 0) + 's');
          print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
        });
      }
    "
  else
    [[ -z "$DB_NAME" ]] && die "-indexes without a collection name requires -db <database>"
    print_info "All collections in database: ${DB_NAME}   scale: ${SCALE_LABEL}"
    run_mongosh "
      var unit  = '${SCALE_LABEL}';
      var sc    = ${SCALE};
      function lp(v, n) { return String(v).padEnd(n); }
      function rp(v, n) { return String(v).padStart(n); }

      var names    = db.getCollectionNames();
      var sep      = '  ' + '\u2500'.repeat(82);
      var hdr      = '  ' + lp('Collection', 28) + rp('Indexes', 9) +
                     rp('Total (' + unit + ')', 22) + rp('Avg/index (' + unit + ')', 22);
      var totIdx = 0, totSz = 0;
      var rows = [];
      names.forEach(function(name) {
        var s = db.getCollection(name).stats({ scale: sc });
        totIdx += s.nindexes;
        totSz  += s.totalIndexSize;
        rows.push({ name: name, n: s.nindexes, sz: s.totalIndexSize });
      });
      print(sep); print(hdr); print(sep);
      rows.forEach(function(r) {
        var avg = r.n > 0 ? (r.sz / r.n).toFixed(4) : '\u2014';
        print('  ' + lp(r.name, 28) + rp(r.n, 9) + rp(r.sz.toFixed(4), 22) + rp(avg, 22));
      });
      print(sep);
      print('  ' + lp('TOTAL (' + names.length + ' collections)', 28) +
            rp(totIdx, 9) + rp(totSz.toFixed(4), 22) + rp('\u2014', 22));
      print(sep);

      var builds = db.currentOp({
        \$or: [
          { 'command.createIndexes': { \$exists: true } },
          { msg: /Index Build/i }
        ]
      }).inprog || [];
      print('');
      print('  \u2500\u2500 Active Index Builds \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      if (builds.length === 0) {
        print('  (none)');
      } else {
        builds.forEach(function(op) {
          var pctVal = (op.progress && op.progress.total > 0)
            ? (op.progress.done / op.progress.total) * 100 : -1;
          var pct = pctVal >= 0
            ? pctVal.toFixed(1) + '%  (' + op.progress.done + ' / ' + op.progress.total + ')'
            : (op.msg || '\u2014');
          if (pctVal > 0 && op.secs_running) {
            var eta = Math.round(op.secs_running * (100 - pctVal) / pctVal);
            pct += '  (~' + eta + 's remaining)';
          }
          print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
          print('  OpID       : ' + op.opid);
          print('  Collection : ' + (op.ns || '\u2014'));
          if (op.command && op.command.indexes) {
            var names2 = op.command.indexes.map(function(i) { return i.name || JSON.stringify(i.key); }).join(', ');
            print('  Index(es)  : ' + names2);
          }
          print('  Progress   : ' + pct);
          print('  Running    : ' + (op.secs_running || 0) + 's');
          print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
        });
      }
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

    // ── Latency Percentiles ───────────────────────────────────────────────
    print("  \u2500\u2500 Latency Percentiles (cumulative since restart) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    try {
      var latResp = db.adminCommand({ serverStatus: 1, opLatencies: { histograms: true } });
      var latData = latResp.opLatencies || {};

      function computePct(histogram, totalOps, pct) {
        if (!histogram || !histogram.length || totalOps === 0) return -1;
        var target = Math.ceil(totalOps * pct / 100);
        var cumul = 0;
        for (var bi = 0; bi < histogram.length; bi++) {
          cumul += histogram[bi].count;
          if (cumul >= target) return histogram[bi].micros / 1000;
        }
        return histogram[histogram.length - 1].micros / 1000;
      }

      function fmtMs(v) {
        if (v < 0) return "N/A".padStart(9);
        return (v.toFixed(2) + "ms").padStart(9);
      }

      var latSep = "  " + "\u2500".repeat(62);
      var latHdr = "  " + "Type".padEnd(10) + "Ops".padStart(12) +
                   "Avg".padStart(10) + "P50".padStart(10) +
                   "P95".padStart(10) + "P99".padStart(10);
      print(latSep);
      print(latHdr);
      print(latSep);

      var latTypes = [
        { name: "Reads",    d: latData.reads    },
        { name: "Writes",   d: latData.writes   },
        { name: "Commands", d: latData.commands }
      ];
      var writePct99 = -1;
      var readPct99  = -1;

      latTypes.forEach(function(t) {
        var d     = t.d || {};
        var ops   = (d.ops     && d.ops.toNumber)     ? d.ops.toNumber()     : Number(d.ops     || 0);
        var latUs = (d.latency && d.latency.toNumber) ? d.latency.toNumber() : Number(d.latency || 0);
        var avgMs = ops > 0 ? latUs / ops / 1000 : 0;
        var hist  = d.histogram || [];
        var p50   = computePct(hist, ops, 50);
        var p95   = computePct(hist, ops, 95);
        var p99   = computePct(hist, ops, 99);
        if (t.name === "Writes") writePct99 = p99;
        if (t.name === "Reads")  readPct99  = p99;
        print("  " + t.name.padEnd(10) + String(ops).padStart(12) +
              fmtMs(avgMs) + fmtMs(p50) + fmtMs(p95) + fmtMs(p99));
      });
      print(latSep);

      if (writePct99 > 20)
        recs.push("  [INFO] Write P99 " + writePct99.toFixed(2) + "ms > 20ms. Investigate with -tcbstats and -indexes.");
      if (readPct99 > 50)
        recs.push("  [INFO] Read P99 " + readPct99.toFixed(2) + "ms > 50ms. Check for COLLSCAN operations with -dynamic.");
    } catch(latErr) {
      print("  (latency histogram unavailable: " + latErr.message + ")");
    }
    print("");

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
    print_info "Filter: active operations running longer than ${SECS}s"
  else
    print_info "Filter: all active operations"
  fi

  run_mongosh "
    var thresh   = ${secs_threshold};
    var active   = db.currentOp({ active: true, secs_running: { \$gt: thresh } }).inprog || [];
    var inactive = (db.currentOp({ active: false }).inprog || []).filter(function(op) {
      return op.transaction != null;
    });
    var ss  = db.serverStatus();
    var txn = ss.transactions || {};
    var wt  = (ss.wiredTiger && ss.wiredTiger.transaction) ? ss.wiredTiger.transaction : {};

    function toLong(v) {
      if (!v) return 0;
      return (typeof v === 'object' && v.toNumber) ? v.toNumber() : Number(v);
    }

    print('  \u2500\u2500 Active Operations \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
    if (active.length === 0) {
      print('  (no active operations matching filter)');
    } else {
      active.forEach(function(op) {
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
        print('  OpID        : ' + op.opid);
        print('  Operation   : ' + op.op);
        print('  Namespace   : ' + (op.ns || '\u2014'));
        print('  Running     : ' + (op.secs_running || 0) + 's');
        if (op.transaction && op.transaction.parameters) {
          print('  TxnNumber   : ' + op.transaction.parameters.txnNumber);
        }
        if (op.waitingForLock) print('  Lock wait   : YES  << BLOCKED');
        print('  Client      : ' + (op.client || '\u2014'));
        if (op.appName) print('  App         : ' + op.appName);
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      });
    }

    print('');
    print('  \u2500\u2500 Inactive Sessions (open transaction, not executing) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
    if (inactive.length === 0) {
      print('  (none)');
    } else {
      inactive.forEach(function(op) {
        var secs = op.secs_running || 0;
        var warn = secs > 30 ? '  << WARNING' : (secs > 10 ? '  << ELEVATED' : '');
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
        print('  OpID        : ' + op.opid);
        print('  Open for    : ' + secs + 's' + warn);
        print('  Namespace   : ' + (op.ns || '\u2014'));
        if (op.transaction && op.transaction.parameters) {
          print('  TxnNumber   : ' + op.transaction.parameters.txnNumber);
        }
        print('  Client      : ' + (op.client || '\u2014'));
        if (op.appName) print('  App         : ' + op.appName);
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      });
    }

    print('');
    print('  \u2500\u2500 Transaction Counters \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
    var curActive   = txn.currentActive   || 0;
    var curInactive = txn.currentInactive || 0;
    var curOpen     = txn.currentOpen     || 0;
    var committed   = toLong(txn.totalCommitted);
    var aborted     = toLong(txn.totalAborted);
    var started     = toLong(txn.totalStarted);
    var conflicts   = toLong(wt['transaction conflict between concurrent transactions']);
    var abortRate   = started > 0 ? ((aborted / started) * 100).toFixed(2) : '0.00';
    var confLabel   = conflicts > 100 ? '  << ELEVATED' : '  OK';

    print('  Active now       : ' + curActive);
    print('  Inactive now     : ' + curInactive + (curInactive > 0 ? '  << check inactive sessions above' : ''));
    print('  Open total       : ' + curOpen);
    print('  Committed        : ' + committed);
    print('  Aborted          : ' + aborted);
    print('  Abort rate       : ' + abortRate + '%');
    print('  Write conflicts  : ' + conflicts + confLabel);

    print('');
    print('  \u2500\u2500 Recommendations \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
    var recs = [];
    if (curInactive > 0) {
      recs.push('  [WARN] ' + curInactive + ' inactive transaction(s) detected.' +
        '\n         Idle open transactions hold document-level locks and cause' +
        '\n         write conflict retries on concurrent writers.' +
        '\n         Action: use -wlocks to identify blockers; close the stalled session.');
    }
    if (parseFloat(abortRate) >= 5) {
      recs.push('  [WARN] Abort rate at ' + abortRate + '%. High write conflict or timeout rate.' +
        '\n         Action: reduce transaction scope; check for hot documents.');
    }
    if (conflicts > 100) {
      recs.push('  [INFO] Write conflicts elevated (' + conflicts + '). Concurrent writers are' +
        '\n         retrying. Common cause: long-lived read transactions or hot documents.' +
        '\n         Action: reduce transaction duration; shard hot collections if needed.');
    }
    if (recs.length === 0) {
      recs.push('  [OK] No transaction anomalies detected.');
    }
    recs.forEach(function(r) { print(r); });
  "

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

  run_mongosh "
    var ops = db.currentOp({ active: true, secs_running: { \$gt: ${secs_threshold} } }).inprog || [];
    if (ops.length === 0) {
      print('  (no operations running longer than ${secs_threshold}s)');
    } else {
      ops.forEach(function(op) {
        var desc = '\u2014';
        if (op.msg) {
          desc = op.msg;
        } else if (op.command) {
          var k = Object.keys(op.command)[0];
          if (k) desc = k + ': ' + (op.command[k] || '');
        }
        var pct = '\u2014';
        if (op.progress && op.progress.total > 0) {
          var pctVal = (op.progress.done / op.progress.total) * 100;
          pct = pctVal.toFixed(1) + '%  (' + op.progress.done + ' / ' + op.progress.total + ')';
          if (pctVal > 0 && op.secs_running) {
            var eta = Math.round(op.secs_running * (100 - pctVal) / pctVal);
            pct += '  (~' + eta + 's remaining)';
          }
        }
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
        print('  OpID        : ' + op.opid);
        print('  Type        : ' + op.op + (op.type ? '  (' + op.type + ')' : ''));
        print('  Namespace   : ' + (op.ns || '\u2014'));
        print('  Running     : ' + (op.secs_running || 0) + 's');
        print('  Progress    : ' + pct);
        print('  Description : ' + desc);
        print('  Waiting     : ' + (op.waitingForLock ? 'YES  << BLOCKED' : 'NO'));
        print('  Client      : ' + (op.client || '\u2014'));
        if (op.appName) print('  App         : ' + op.appName);
        print('  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500');
      });
      print('  Total: ' + ops.length + ' long-running operation(s)');
    }
  "

  print_footer
}

# ─────────────────────────────────────────────────────────────
#  3.7  Background data movement      equiv: db2pd -reorgs
# ─────────────────────────────────────────────────────────────
cmd_reorgs() {
  print_header "Background Builds and Data Movement  [equiv: db2pd -reorgs]"

  run_mongosh '
    var all = db.currentOp({
      $or: [
        { "command.createIndexes": { $exists: true } },
        { "msg": /Index Build/i },
        { "msg": /compact/i },
        { "msg": /migration|resharding/i }
      ]
    }).inprog || [];

    var builds     = all.filter(function(op) { return /Index Build/i.test(op.msg || "") || (op.command && op.command.createIndexes); });
    var compacts   = all.filter(function(op) { return /compact/i.test(op.msg || ""); });
    var migrations = all.filter(function(op) { return /migration|resharding/i.test(op.msg || ""); });

    function printOp(op, type) {
      var pctVal = (op.progress && op.progress.total > 0)
        ? (op.progress.done / op.progress.total) * 100 : -1;
      var pct = pctVal >= 0
        ? pctVal.toFixed(1) + "%  (" + op.progress.done + " / " + op.progress.total + ")"
        : (op.msg || "\u2014");
      if (pctVal > 0 && op.secs_running) {
        var eta = Math.round(op.secs_running * (100 - pctVal) / pctVal);
        pct += "  (~" + eta + "s remaining)";
      }
      print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
      print("  OpID        : " + op.opid);
      print("  Collection  : " + (op.ns || "\u2014"));
      if (type === "index" && op.command && op.command.indexes) {
        var idxNames = op.command.indexes.map(function(i) { return i.name || JSON.stringify(i.key); }).join(", ");
        print("  Index(es)   : " + idxNames);
      }
      print("  Running     : " + (op.secs_running || 0) + "s");
      print("  Progress    : " + pct);
      if (op.msg) print("  Phase       : " + op.msg);
      print("  Client      : " + (op.client || "\u2014"));
      if (op.appName) print("  App         : " + op.appName);
      print("  \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    }

    print("  \u2500\u2500 Background Index Builds \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    if (builds.length === 0) {
      print("  (none)");
    } else {
      builds.forEach(function(op) { printOp(op, "index"); });
    }

    print("");
    print("  \u2500\u2500 Compact Operations \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    if (compacts.length === 0) {
      print("  (none)");
    } else {
      compacts.forEach(function(op) { printOp(op, "compact"); });
    }

    print("");
    print("  \u2500\u2500 Data Migrations / Resharding \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500");
    if (migrations.length === 0) {
      print("  (none)");
    } else {
      migrations.forEach(function(op) { printOp(op, "migration"); });
    }
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
  -tcbstats [collection] Per-collection performance snapshot    ($collStats)
  -tables  [collection] Collection footprint and storage stats
  -indexes [collection] Index footprint by collection
  -mempools             WiredTiger cache and memory pressure
  -transactions         In-flight transactions and counters
  -utilities            Long-running internal operations
  -reorgs               Background index builds and data movement
  -hadr                 Replica set health and replication state
  -stat                 Real-time throughput monitor            (mongostat)
  -osinfo               Host CPU, memory, disk and I/O metrics (requires local mongod)
  -diag                 Scan mongod log for OOM, crashes and elections (requires local mongod)
  -sharding             Sharding topology, balancer state and chunk distribution (requires mongos)

${BOLD}MODIFIERS${RESET}
  -kill    <opid>       Kill operation by opid (prompts for confirmation)
  -secs    <n>          Filter operations running longer than N seconds
  -slowms  <ms>         Profiler slow-op threshold for -dynamic  (default: 200)
  -profiling [on|off]   Enable/disable profiler (used with -dynamic)
  -limit   <n>          Limit profiler output rows               (default: 20)
  -scale   [mb|gb]      Output scale for -tables and -indexes
  -n       <seconds>    Sampling interval for -stat              (default: 5)
  -lines   <n>          Log lines scanned by -diag               (default: 5000)
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

  # Per-collection performance snapshot (equivalent: db2pd -tcbstats)
  mongopd.sh -host mdb1:27017 -db sales -tcbstats
  mongopd.sh -host mdb1:27017 -db sales -tcbstats orders

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
  Add to ~/.bashrc or ~/.profile:
    alias mpd='mongopd.sh'

  Then use:
    mpd -host mdb1:27017 -db sales -locks wait

${BOLD}REQUIREMENTS${RESET}
  mongosh         — mongodb.com/try/download/shell
  mongostat       — mongodb.com/try/download/database-tools  (for -stat)

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
        FLAG_TCBSTATS=true; (( DISPATCH_COUNT++ )) || true
        if [[ -n "${2:-}" ]] && [[ "${2}" != -* ]]; then
          COLLECTION="$2"; shift
        fi
        shift ;;

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

      -osinfo)
        FLAG_OSINFO=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -diag)
        FLAG_DIAG=true; (( DISPATCH_COUNT++ )) || true; shift ;;

      -sharding)
        FLAG_SHARDING=true; (( DISPATCH_COUNT++ )) || true; shift ;;

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

      -lines)
        [[ -z "${2:-}" ]] && die "-lines requires a number"
        LOG_LINES="$2"; shift 2 ;;

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
  [[ "$FLAG_OSINFO" == "true" ]]       && cmd_osinfo
  [[ "$FLAG_DIAG" == "true" ]]         && cmd_diag
  [[ "$FLAG_SHARDING" == "true" ]]     && cmd_sharding
  [[ "$FLAG_KILL" == "true" ]]         && cmd_kill

  return 0
}

main "$@"
