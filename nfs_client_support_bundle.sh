#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# NFS Client Diagnostics Collector
#
# WHAT IT DOES:
#   Collects comprehensive NFS client diagnostics to help troubleshoot:
#   - Slow NFS performance (high latency, low throughput)
#   - NFS mount hangs or timeouts
#   - Application stalls when accessing NFS mounts
#   - Network connectivity issues to NFS servers
#   - Misconfiguration (slot tables, socket buffers, nconnect, etc.)
#
# USAGE:
#   ./nfs_client_support_bundle.sh [--with-fio <mount_path>]
#
# OPTIONS:
#   --with-fio <mount_path>   Also run fio benchmark against the given NFS
#                             mount and include results in the bundle.
#                             Requires nfs_fio_test.sh in the same directory.
#
# OUTPUT:
#   Creates: nfs_client_collect_YYYYMMDD_HHMMSS.tar.gz (mode 600)
#   Contains: Subdirectory tree of diagnostic text files + QUICKLOOK.txt
#             + MISCONFIG_REPORT.txt
#
# CUSTOMIZE (optional):
#   LOG_SINCE=1h SAMPLE_SEC=5 ./nfs_client_support_bundle.sh
#   PING_COUNT=20 ./nfs_client_support_bundle.sh --with-fio /mnt/vast
#
# SAFETY:
#   - Non-intrusive: Uses nice/ionice to minimize system impact
#   - Bounded: Every command has an explicit timeout
#   - Read-only: Does not modify system state
#   - No filesystem traversal: Does not run find/du on NFS mounts
#   - Credential-safe: Redacts passwords/secrets from mount options
#
###############################################################################

# =================== Argument parsing ===================
FIO_MOUNT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-fio)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: --with-fio requires a mount path argument" >&2
        echo "Usage: $0 [--with-fio <mount_path>]" >&2
        exit 1
      fi
      FIO_MOUNT="$(realpath -e "${2%/}" 2>/dev/null)" || {
        echo "ERROR: '$2' does not exist or cannot be resolved" >&2
        exit 1
      }
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--with-fio <mount_path>]"
      echo "  --with-fio <mount_path>   Run fio benchmark on the given NFS mount"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: $0 [--with-fio <mount_path>]" >&2
      exit 1
      ;;
  esac
done

# =================== Security hardening ===================
# Restrict all created files/dirs to owner-only until we explicitly widen
umask 077

# Explicit PATH — never trust inherited environment
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Save the invoking user before clearing sudo env — used to chown the tarball
# at the end so the user can scp it without needing sudo.
_INVOKE_USER="${SUDO_USER:-}"

# Clear variables that could contain secrets passed in from the environment.
# We only use our own named env-vars below.
for _v in SUDO_COMMAND SUDO_USER SUDO_UID AWS_SECRET_ACCESS_KEY \
           GOOGLE_APPLICATION_CREDENTIALS AZURE_CLIENT_SECRET; do
  unset "$_v" 2>/dev/null || true
done
unset _v

# =================== Config ===================
OUTDIR="$(pwd)/nfs_client_collect_$(date +%Y%m%d_%H%M%S)"
LOG_SINCE="${LOG_SINCE:-now-2h}"     # kernel log window

# Validate numeric env-vars — reject non-numeric values and fall back to defaults
_validate_int() {
  local val="$1" default="$2"
  [[ "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo "$default"
}
_validate_float() {
  local val="$1" default="$2"
  [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$val" || echo "$default"
}
SAMPLE_SEC="$(_validate_int  "${SAMPLE_SEC:-3}"   3)"
PING_COUNT="$(_validate_int  "${PING_COUNT:-10}"  10)"
PING_INT="$(  _validate_float "${PING_INT:-0.2}"  0.2)"

# Per-command timeout constants (seconds)
T_FAST=5          # Quick reads: uname, uptime, free, sysctl
T_NORMAL=10       # Normal commands: mount, nfsstat, ss, ip
T_LOG=20          # Log commands: journalctl, dmesg
T_NETWORK=15      # Network commands: ping, route lookups
T_SAMPLE=$((SAMPLE_SEC + 5))   # Samplers: iostat, nfsiostat, mpstat, vmstat

NICE_CMD=(nice -n 19)
# ionice -c3 (idle class) only available on Linux
if ionice -c3 true 2>/dev/null; then
  NICE_CMD=(nice -n 19 ionice -c3)
fi

# =================== Output directory structure ===================
mkdir -p \
  "$OUTDIR/system" \
  "$OUTDIR/nfs" \
  "$OUTDIR/kernel" \
  "$OUTDIR/sockets" \
  "$OUTDIR/network" \
  "$OUTDIR/performance" \
  "$OUTDIR/logs" \
  "$OUTDIR/storage" \
  "$OUTDIR/resources" \
  "$OUTDIR/per_mount" \
  "$OUTDIR/per_server" \
  "$OUTDIR/k8s"

# =================== Logging ===================
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$OUTDIR/_collector.log"; }

# =================== run() — bounded + nice ===================
# Usage: run <timeout_secs> <outfile_relative_to_OUTDIR> <cmd...>
run() {
  local timeout_secs="$1"; shift
  local outfile="$1";       shift
  {
    printf '## cmd: %s\n## date: %s\n' "$*" "$(date '+%F %T')"
    "${NICE_CMD[@]}" timeout "${timeout_secs}s" "$@" 2>&1 || true
  } > "$OUTDIR/$outfile"
}

# run_root: same as run but prefixes sudo if not already root
run_root() {
  local timeout_secs="$1"; shift
  local outfile="$1";       shift
  if [[ $EUID -eq 0 ]]; then
    run "$timeout_secs" "$outfile" "$@"
  else
    run "$timeout_secs" "$outfile" sudo "$@"
  fi
}

# run_sh: run a shell snippet (needed for pipes, redirects, bash builtins)
run_sh() {
  local timeout_secs="$1"; shift
  local outfile="$1";       shift
  local snippet="$1"
  {
    printf '## cmd: bash -c %q\n## date: %s\n' "$snippet" "$(date '+%F %T')"
    "${NICE_CMD[@]}" timeout "${timeout_secs}s" bash -c "$snippet" 2>&1 || true
  } > "$OUTDIR/$outfile"
}

# =================== Helpers ===================
# Validate that a server address contains only safe characters
# (prevents shell injection when constructing per-server filenames/commands)
validate_host() {
  local h="$1"
  if [[ "$h" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "$h"
    return 0
  fi
  log "WARNING: skipping unsafe server address: $h"
  return 1
}

# Return a filesystem-safe slug from an arbitrary string
slug() { printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'; }

# Redact passwords and secrets from a mount options string
sanitize_mount_opts() {
  # Remove common secret patterns: password=X, secret=X, pass=X, key=X
  printf '%s' "$1" \
    | sed -E 's/(password|passwd|pass|secret|key|token|credential)=[^, ]*/\1=REDACTED/gi'
}

# =================== Detect NFS mounts ===================
log "Auto-detecting NFS mounts..."

declare -A MOUNTS=()    # mountpoint -> server IP/host
declare -A SRCPATHS=()  # mountpoint -> server:/export
declare -A MNTOPTS=()   # mountpoint -> mount options (sanitized)

# Primary: nfsstat -m
if command -v nfsstat >/dev/null 2>&1; then
  current_mp=""
  while IFS= read -r line; do
    if grep -q " from " <<<"$line"; then
      mp="${line% from *}"
      srvp="${line#* from }"
      srvp="${srvp%% *}"
      [[ -z "$mp" ]] && continue
      current_mp="$mp"
      SRCPATHS["$mp"]="$srvp"
    elif [[ -n "$current_mp" ]]; then
      addr=$(sed -n 's#.*addr=\([^, ]*\).*#\1#p' <<<"$line" || true)
      opts=$(sed -n 's#[^(]*(\([^)]*\)).*#\1#p' <<<"$line" || true)
      if [[ -n "$addr" ]]; then
        MOUNTS["$current_mp"]="$addr"
      fi
      if [[ -n "$opts" ]]; then
        MNTOPTS["$current_mp"]="$(sanitize_mount_opts "$opts")"
        current_mp=""
      fi
    fi
  done < <(nfsstat -m 2>/dev/null || true)
fi

# Fallback: /proc/self/mountstats
if [[ ${#MOUNTS[@]} -eq 0 ]]; then
  while IFS= read -r line; do
    dev=$(awk '{print $2}' <<<"$line")
    mp=$(awk '{print $5}' <<<"$line")
    [[ -z "$mp" || -z "$dev" ]] && continue
    host="${dev%%:*}"
    MOUNTS["$mp"]="$host"
    SRCPATHS["$mp"]="$dev"
  done < <(grep -E '^device .* mounted on .* type nfs' /proc/self/mountstats 2>/dev/null || true)
fi

# Fallback: /proc/mounts
if [[ ${#MOUNTS[@]} -eq 0 ]]; then
  while read -r dev mp fstype opts _; do
    [[ "$fstype" =~ ^nfs ]] || continue
    host="${dev%%:*}"
    MOUNTS["$mp"]="$host"
    SRCPATHS["$mp"]="$dev"
    MNTOPTS["$mp"]="$(sanitize_mount_opts "$opts")"
  done < /proc/mounts 2>/dev/null || true
fi

HAS_MOUNTS=false
if [[ ${#MOUNTS[@]} -eq 0 ]]; then
  log "WARNING: No NFS mounts detected. Collecting system-level diagnostics only."
else
  HAS_MOUNTS=true
  log "Detected ${#MOUNTS[@]} NFS mount(s):"
  for mp in "${!MOUNTS[@]}"; do
    log " - $mp  (server=${MOUNTS[$mp]} source=${SRCPATHS[$mp]:-N/A})"
  done
fi

# =================== Detect NFS versions in use ===================
HAS_NFSv3=false
HAS_NFSv4=false
while read -r _ mp fstype _; do
  [[ "$fstype" == "nfs" ]]  && HAS_NFSv3=true
  [[ "$fstype" == "nfs4" ]] && HAS_NFSv4=true
done < /proc/mounts 2>/dev/null || true

log "NFS versions detected: v3=$HAS_NFSv3 v4=$HAS_NFSv4"

###############################################################################
### SYSTEM CONTEXT
###############################################################################
log "Collecting system context..."
run    $T_FAST    "system/uname.txt"          uname -a
run    $T_FAST    "system/hostname.txt"        hostname -f
run    $T_FAST    "system/uptime.txt"          uptime
run    $T_FAST    "system/free.txt"            free -h

if command -v lsb_release >/dev/null 2>&1; then
  run  $T_FAST    "system/lsb_release.txt"     lsb_release -a
else
  run_sh $T_FAST  "system/os_release.txt"      "cat /etc/os-release 2>/dev/null || true"
fi

# Package versions — NFS client kernel module and user-space tools
if command -v dpkg >/dev/null 2>&1; then
  run_sh $T_FAST  "system/packages.txt" \
    "dpkg -l 2>/dev/null | grep -E -i '(^ii.*(nfs|sysstat|nfs-common|nfs-utils|rpcbind|nfs-kernel-server))' || true"
elif command -v rpm >/dev/null 2>&1; then
  run_sh $T_FAST  "system/packages.txt" \
    "rpm -qa 2>/dev/null | grep -E -i '(nfs|sysstat|rpcbind)' | sort || true"
else
  printf 'No package manager (dpkg/rpm) detected.\n' > "$OUTDIR/system/packages.txt"
fi

# Loaded kernel modules relevant to NFS
run_sh $T_FAST    "system/nfs_modules.txt" \
  "lsmod 2>/dev/null | grep -E '(nfs|sunrpc|lockd|rpcrdma|nfs_acl|nfsv4|nfsv3)' || true"

# Full kernel module info for nfs and sunrpc
for mod in nfs sunrpc nfsv4 lockd; do
  if lsmod 2>/dev/null | grep -q "^${mod}"; then
    run_sh $T_FAST "system/modinfo_${mod}.txt" "modinfo ${mod} 2>/dev/null || true"
  fi
done

###############################################################################
### SYSCTL — NFS/sunrpc/socket parameters
###############################################################################
log "Collecting sysctl parameters..."
run_sh $T_FAST    "system/sysctl_nfs.txt" \
  "sysctl -a 2>/dev/null | grep -E '^(sunrpc|fs\.nfs|fs\.nfsd|net\.ipv4|net\.core|net\.unix|vm\.dirty|kernel\.hostname)' | sort || true"

# Highlight the specific values we care about most
{
  printf '## Key NFS/socket parameters\n'
  for key in \
    sunrpc.tcp_slot_table_entries \
    sunrpc.udp_slot_table_entries \
    sunrpc.max_tcp_slot_table_entries \
    net.core.rmem_max \
    net.core.wmem_max \
    net.core.rmem_default \
    net.core.wmem_default \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.tcp_retries2 \
    net.ipv4.tcp_syn_retries \
    net.ipv4.tcp_keepalive_time \
    fs.nfs.nfs_congestion_kb \
    vm.dirty_ratio \
    vm.dirty_background_ratio \
    vm.dirty_bytes \
    vm.dirty_background_bytes \
    vm.dirty_expire_centisecs \
    vm.dirty_writeback_centisecs; do
    val=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
    printf '%-50s = %s\n' "$key" "$val"
  done
} > "$OUTDIR/system/sysctl_key_params.txt"

###############################################################################
### NFS MOUNTS AND CLIENT STATS
###############################################################################
if [[ "$HAS_MOUNTS" == "false" ]]; then
  log "Skipping NFS mount/client stats (no mounts detected)"
else
log "Collecting NFS mount and client statistics..."

run    $T_NORMAL  "nfs/mounts.txt"            mount -t nfs,nfs4
run_sh $T_NORMAL  "nfs/proc_mounts.txt"       "grep -E ' (nfs|nfs4) ' /proc/mounts 2>/dev/null || true"
run_sh $T_NORMAL  "nfs/proc_mountstats.txt"   "cat /proc/self/mountstats 2>/dev/null || true"
run_sh $T_NORMAL  "nfs/fstab_nfs.txt"         "grep -E '(nfs|nfs4)' /etc/fstab 2>/dev/null | sed -E 's/(password|passwd|pass|secret|key|token)=[^, ]*/\1=REDACTED/gi' || true"

# nfsstat suite
if command -v nfsstat >/dev/null 2>&1; then
  run  $T_NORMAL  "nfs/nfsstat_m.txt"         nfsstat -m
  run  $T_NORMAL  "nfs/nfsstat_client.txt"    nfsstat -c
  run  $T_NORMAL  "nfs/nfsstat_rpc.txt"       nfsstat -r
  run  $T_NORMAL  "nfs/nfsstat_net.txt"       nfsstat -n
fi

# /proc/net/rpc counters
run_sh $T_FAST    "nfs/proc_net_rpc_nfs.txt"  "cat /proc/net/rpc/nfs 2>/dev/null || true"
run_sh $T_FAST    "nfs/proc_net_rpc_nfsd.txt" "cat /proc/net/rpc/nfsd 2>/dev/null || true"

# mountstats summary
if command -v mountstats >/dev/null 2>&1; then
  run  $T_NORMAL  "nfs/mountstats_summary.txt" mountstats
fi

###############################################################################
### NFSv3-SPECIFIC DIAGNOSTICS
###############################################################################
if [[ "$HAS_NFSv3" == "true" ]]; then
  log "Collecting NFSv3-specific diagnostics (rpcbind, statd, lockd)..."

  # rpcbind / portmapper
  if command -v rpcinfo >/dev/null 2>&1; then
    run  $T_NORMAL "nfs/rpcinfo_p.txt"        rpcinfo -p localhost
    run  $T_NORMAL "nfs/rpcinfo_s.txt"        rpcinfo -s localhost
  fi

  # Port usage for well-known NFSv3 services
  run_sh $T_NORMAL "nfs/nfsv3_ports.txt" \
    "ss -tlnp 2>/dev/null | grep -E ':(111|2049|875|20048|4001)' || true"

  # rpcbind service status
  if command -v systemctl >/dev/null 2>&1; then
    run_sh $T_FAST "nfs/rpcbind_status.txt" \
      "systemctl status rpcbind rpc-statd nfs-client.target 2>/dev/null || true"
  fi

  # statd and lockd kernel parameters
  run_sh $T_FAST "nfs/lockd_params.txt" \
    "cat /proc/fs/lockd/nlm_grace_period 2>/dev/null; cat /proc/fs/lockd/nlm_timeout 2>/dev/null; sysctl -a 2>/dev/null | grep lockd || true"
fi

###############################################################################
### NFSv4-SPECIFIC DIAGNOSTICS
###############################################################################
if [[ "$HAS_NFSv4" == "true" ]]; then
  log "Collecting NFSv4-specific diagnostics..."

  # idmapd status
  if command -v systemctl >/dev/null 2>&1; then
    run_sh $T_FAST "nfs/nfsv4_idmapd_status.txt" \
      "systemctl status nfs-idmapd rpc-idmapd 2>/dev/null || true"
  fi

  # /etc/idmapd.conf — safe to include (no secrets)
  run_sh $T_FAST "nfs/nfsv4_idmapd_conf.txt" \
    "cat /etc/idmapd.conf 2>/dev/null || true"

  # NFSv4 lease time
  run_sh $T_FAST "nfs/nfsv4_lease.txt" \
    "cat /proc/fs/nfsfs/servers 2>/dev/null || true; cat /proc/fs/nfsfs/volumes 2>/dev/null || true"

  # NFSv4.1/4.2 session info
  run_sh $T_FAST "nfs/nfsv4_sessions.txt" \
    "ls /proc/fs/nfsfs/ 2>/dev/null; cat /proc/fs/nfsfs/servers 2>/dev/null; cat /proc/fs/nfsfs/volumes 2>/dev/null || true"
fi

fi  # end HAS_MOUNTS block

###############################################################################
### SOCKET DIAGNOSTICS
###############################################################################
log "Collecting socket diagnostics..."

# All TCP connections to NFS port 2049
run_sh $T_NORMAL "sockets/ss_nfs_connections.txt" \
  "ss -tniop 'dport = :2049' 2>/dev/null || ss -tnop 'dport = :2049' 2>/dev/null || true"

# Summary of all TCP sockets
run_sh $T_NORMAL "sockets/ss_summary.txt" \
  "ss -s 2>/dev/null || true"

# Detailed TCP socket state with send/recv queue and timer info
run_sh $T_NORMAL "sockets/ss_tni.txt" \
  "ss -tni 2>/dev/null || true"

# Unix sockets (RPC sunrpc uses unix sockets internally)
run_sh $T_FAST   "sockets/ss_unix_rpc.txt" \
  "ss -xnp 2>/dev/null | grep -E '(rpc|sunrpc|nfs|portmap)' || true"

# TCP socket buffer configuration
{
  printf '## Socket buffer configuration\n'
  printf '## net.core.rmem_max = %s\n'    "$(sysctl -n net.core.rmem_max 2>/dev/null || echo N/A)"
  printf '## net.core.wmem_max = %s\n'    "$(sysctl -n net.core.wmem_max 2>/dev/null || echo N/A)"
  printf '## net.core.rmem_default = %s\n' "$(sysctl -n net.core.rmem_default 2>/dev/null || echo N/A)"
  printf '## net.core.wmem_default = %s\n' "$(sysctl -n net.core.wmem_default 2>/dev/null || echo N/A)"
  printf '## net.ipv4.tcp_rmem = %s\n'    "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo N/A)"
  printf '## net.ipv4.tcp_wmem = %s\n'    "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo N/A)"
  printf '\n## nconnect connections per mount (from ss):\n'
  ss -tn 'dport = :2049' 2>/dev/null | grep -c 'ESTAB' || true
  printf '\n## All NFS connections:\n'
  ss -tn 'dport = :2049' 2>/dev/null || true
} > "$OUTDIR/sockets/socket_buffer_config.txt"

# /proc/net/snmp — TCP/IP counters (RetransSegs, InErrs, etc.)
run_sh $T_FAST "sockets/proc_net_snmp.txt" \
  "cat /proc/net/snmp 2>/dev/null || true"

# /proc/net/netstat — extended TCP counters (TCPRetransFail, TCPTimeouts, etc.)
run_sh $T_FAST "sockets/proc_net_netstat.txt" \
  "cat /proc/net/netstat 2>/dev/null || true"

# RPC-specific socket stats from sunrpc
run_sh $T_FAST "sockets/sunrpc_stats.txt" \
  "cat /proc/net/rpc/nfs 2>/dev/null; cat /proc/sys/sunrpc/tcp_slot_table_entries 2>/dev/null; cat /proc/sys/sunrpc/udp_slot_table_entries 2>/dev/null; cat /proc/sys/sunrpc/max_tcp_slot_table_entries 2>/dev/null || true"

###############################################################################
### NETWORK DIAGNOSTICS (system-wide)
###############################################################################
log "Collecting network diagnostics..."

run    $T_NORMAL  "network/ip_link_stats.txt"   ip -s link
run_sh $T_NORMAL  "network/ip_addr.txt"          "ip addr show"
run_sh $T_NORMAL  "network/ip_route.txt"         "ip route show"

if command -v netstat >/dev/null 2>&1; then
  run  $T_NORMAL  "network/netstat_s.txt"        netstat -s
fi

###############################################################################
### PERFORMANCE SAMPLERS
###############################################################################
log "Collecting performance samples (${SAMPLE_SEC}s each)..."

if command -v nfsiostat >/dev/null 2>&1; then
  run  $T_SAMPLE  "performance/nfsiostat.txt"    nfsiostat 1 "$SAMPLE_SEC"
fi
if command -v iostat >/dev/null 2>&1; then
  run  $T_SAMPLE  "performance/iostat_x.txt"     iostat -x 1 "$SAMPLE_SEC"
fi
if command -v mpstat >/dev/null 2>&1; then
  run  $T_SAMPLE  "performance/mpstat.txt"       mpstat 1 "$SAMPLE_SEC"
fi
run    $T_SAMPLE  "performance/vmstat.txt"       vmstat 1 "$SAMPLE_SEC"

###############################################################################
### KERNEL LOGS
###############################################################################
log "Collecting kernel logs..."

normalize_since() {
  local s="${1:-now-2h}"
  # Accept '2h', '30m', '1d', '7w', '45s' etc. -> convert to 'now-2h' style
  if [[ "$s" =~ ^[0-9]+[smhdw]$ ]]; then
    echo "now-${s}"
    return
  fi
  echo "$s"
}

if command -v journalctl >/dev/null 2>&1; then
  SINCE_ARG="$(normalize_since "$LOG_SINCE")"
  SINCE_ARG="${SINCE_ARG//[\'\"\\]/}"
  if journalctl -k --since "$SINCE_ARG" --no-pager >/dev/null 2>&1; then
    run_sh $T_LOG "logs/kernel_journal.txt" \
      "journalctl -k --since '$SINCE_ARG' --no-pager 2>/dev/null | tail -n 3000"
  else
    run_sh $T_LOG "logs/kernel_journal.txt" \
      "journalctl -k -n 3000 --no-pager 2>/dev/null || true"
  fi

  # NFS/RPC-specific journal entries
  run_sh $T_LOG "logs/nfs_journal_entries.txt" \
    "journalctl -k --since '$SINCE_ARG' --no-pager 2>/dev/null | grep -E -i '(nfs|sunrpc|rpc|lockd|portmap|rpcbind|statd)' | tail -n 2000 || true"
else
  run_sh $T_LOG "logs/dmesg.txt" \
    "dmesg 2>/dev/null | tail -n 3000"
  run_sh $T_LOG "logs/dmesg_nfs.txt" \
    "dmesg 2>/dev/null | grep -E -i '(nfs|sunrpc|rpc|lockd|portmap|rpcbind|statd)' || true"
fi

###############################################################################
### STORAGE / BLOCK DEVICES (VM perspective)
# NOTE: Inside the VM, local persistent disks appear as /dev/sda, /dev/sdb, etc.
# The VM has no visibility into the underlying hypervisor storage driver.
# We collect generic block-device and filesystem stats only.
###############################################################################
log "Collecting storage/block device info (VM perspective)..."

run_sh $T_NORMAL  "storage/lsblk.txt" \
  "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,RO 2>/dev/null || true"

run_sh $T_NORMAL  "storage/df_all.txt" \
  "df -hT 2>/dev/null || true"

# dmesg errors for sd* block devices (I/O errors, timeouts from VM's vantage)
run_sh $T_NORMAL  "storage/dmesg_block_errors.txt" \
  "dmesg 2>/dev/null | grep -E -i '(sd[a-z]|blk_|I/O error|Buffer I/O|reset.*SCSI|sense|medium error)' | tail -n 500 || true"

###############################################################################
### RESOURCES (CPU/memory at time of collection)
###############################################################################
log "Collecting resource snapshot..."

run    $T_FAST    "resources/free.txt"          free -h
run_sh $T_FAST    "resources/proc_meminfo.txt"  "cat /proc/meminfo 2>/dev/null || true"
run_sh $T_FAST    "resources/proc_loadavg.txt"  "cat /proc/loadavg 2>/dev/null || true"
run_sh $T_FAST    "resources/proc_vmstat.txt"   "cat /proc/vmstat 2>/dev/null | grep -E '(dirty|writeback|nfs|swap|pgmajfault)' || true"

# top snapshot — batch mode, single iteration
run_sh $T_FAST    "resources/top.txt" \
  "top -b -n 1 2>/dev/null || true"

# ps full snapshot sorted by CPU, then by memory
run_sh $T_FAST    "resources/ps_cpu.txt" \
  "ps -eo pid,ppid,stat,pcpu,pmem,vsz,rss,comm,args --sort=-%cpu 2>/dev/null | head -60 || true"
run_sh $T_FAST    "resources/ps_mem.txt" \
  "ps -eo pid,ppid,stat,pcpu,pmem,vsz,rss,comm,args --sort=-%mem 2>/dev/null | head -60 || true"

# Number of processes in D-state (uninterruptible sleep — often I/O blocked)
run_sh $T_FAST    "resources/dstate_procs.txt" \
  "ps -eo pid,stat,comm,wchan 2>/dev/null | awk '\$2~/^D/{print}' || true"

###############################################################################
### PROCESS-LEVEL NFS ACTIVITY
###############################################################################
if [[ "$HAS_MOUNTS" == "true" ]]; then
log "Collecting process-level NFS activity..."

# Snippet for /proc/fd scan used as lsof fallback.
# Passed to "bash -c" so single quotes inside are literal (nowdoc assignment).
read -r -d '' _proc_fd_snippet <<'PROC_FD_SNIPPET' || true
mp="$1"
for pidfd in /proc/[0-9]*/fd; do
  pid="${pidfd%/fd}"
  pid="${pid#/proc/}"
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  count=$(readlink "$pidfd/"* 2>/dev/null \
    | awk -v m="$mp" 'substr($0,1,length(m)+1)==m"/" {n++} END{print n+0}')
  [[ "$count" -gt 0 ]] || continue
  uid=$(awk '/^Uid:/{print $2; exit}' /proc/"$pid"/status 2>/dev/null || echo "?")
  comm=$(cat /proc/"$pid"/comm 2>/dev/null || echo "?")
  printf "%-8s %-8s %-16s %-30s %s\n" "$pid" "$uid" "$comm" "$mp" "$count"
done
PROC_FD_SNIPPET

# ---- resources/nfs_procs.txt: PIDs with open files on any NFS mount --------
{
  printf '## cmd: NFS process scan\n## date: %s\n' "$(date '+%F %T')"
  if command -v lsof >/dev/null 2>&1; then
    printf '## method: lsof\n'
    for _mp in "${!MOUNTS[@]}"; do
      printf '\n## mount: %s\n' "$_mp"
      timeout "${T_NORMAL}s" lsof -n -P +D "$_mp" 2>/dev/null || true
    done
  else
    printf '## method: /proc/fd scan\n'
    printf '%-8s %-8s %-16s %-30s %s\n' "pid" "uid" "comm" "mount" "open_files"
    for _mp in "${!MOUNTS[@]}"; do
      timeout "${T_NORMAL}s" bash -c "$_proc_fd_snippet" _ "$_mp" 2>/dev/null || true
    done
  fi
} > "$OUTDIR/resources/nfs_procs.txt"

# ---- resources/nfs_proc_io.txt: /proc/<pid>/io for each NFS process --------
{
  printf '## cmd: /proc/pid/io for NFS-connected processes\n## date: %s\n' "$(date '+%F %T')"
  # Extract unique numeric PIDs from nfs_procs.txt.
  # lsof format:     col1=COMMAND (alphabetic), col2=PID (numeric)
  # fallback format: col1=pid (numeric),        col2=uid (numeric)
  _nfs_pids=$(awk '
    /^##/{next}
    $1~/^[A-Za-z]/ && $2~/^[0-9]+$/{print $2}
    $1~/^[0-9]+$/ && $2~/^[0-9]+$/{print $1}
  ' "$OUTDIR/resources/nfs_procs.txt" 2>/dev/null | sort -un || true)
  if [[ -z "$_nfs_pids" ]]; then
    printf '(no NFS processes found)\n'
  else
    while IFS= read -r _pid; do
      [[ "$_pid" =~ ^[0-9]+$ ]] || continue
      _comm=$(cat /proc/"$_pid"/comm 2>/dev/null || echo '?')
      printf '\n## pid=%s comm=%s\n' "$_pid" "$_comm"
      cat /proc/"$_pid"/io 2>/dev/null || printf '  (io file not readable)\n'
    done <<< "$_nfs_pids"
  fi
} > "$OUTDIR/resources/nfs_proc_io.txt"

fi  # end PROCESS-LEVEL NFS ACTIVITY

###############################################################################
### PER-MOUNT DIAGNOSTICS
###############################################################################
if [[ "$HAS_MOUNTS" == "false" ]]; then
  log "Skipping per-mount diagnostics (no mounts detected)"
else
log "Collecting per-mount diagnostics..."

for mp in "${!MOUNTS[@]}"; do
  safe_mp="$(slug "$mp")"
  mkdir -p "$OUTDIR/per_mount/${safe_mp}"

  log "  Mount: $mp"

  # Export mount path for awk snippets (avoids printf '%q' / ENVIRON mismatch)
  export NFS_MP="$mp"

  # Filesystem usage (bounded — df on NFS can stall if server unreachable)
  run $T_NETWORK "per_mount/${safe_mp}/df.txt" df -hT "$mp"

  # Detailed mountstats slice for this mount
  run_sh $T_NORMAL "per_mount/${safe_mp}/mountstats.txt" \
    "awk 'BEGIN{p=0; mp=ENVIRON[\"NFS_MP\"]} /^device .* mounted on /{if(p) exit} index(\$0,\" on \"mp\" \"){p=1} p{print}' /proc/self/mountstats 2>/dev/null || true"

  # Mount options for this specific mount (sanitized)
  printf '## Mount options for: %s\n%s\n' "$mp" "${MNTOPTS[$mp]:-N/A}" \
    > "$OUTDIR/per_mount/${safe_mp}/mount_opts.txt"

  # nfsstat per-mount
  if command -v nfsstat >/dev/null 2>&1; then
    run_sh $T_NORMAL "per_mount/${safe_mp}/nfsstat_m.txt" \
      "nfsstat -m 2>/dev/null | awk 'BEGIN{mp=ENVIRON[\"NFS_MP\"]} p && /^[[:space:]]/{print; next} index(\$0,mp){p=1; print; next} {p=0}' || true"
  fi

  # Processes with open files on this specific mount
  {
    printf '## cmd: active processes on %s\n## date: %s\n' "$mp" "$(date '+%F %T')"
    _found=false
    if command -v lsof >/dev/null 2>&1; then
      _lsof_out=$(timeout "${T_NORMAL}s" lsof -n -P +D "$mp" 2>/dev/null || true)
      if [[ -n "$_lsof_out" ]]; then
        printf '%s\n' "$_lsof_out"
        _found=true
      fi
    else
      _scan_out=$(timeout "${T_NORMAL}s" bash -c "$_proc_fd_snippet" _ "$mp" 2>/dev/null || true)
      _data_lines=$(printf '%s\n' "$_scan_out" | tail -n +2 || true)
      if [[ -n "$_data_lines" ]]; then
        printf '%-8s %-8s %-16s %-30s %s\n' "pid" "uid" "comm" "mount" "open_files"
        printf '%s\n' "$_data_lines"
        _found=true
      fi
    fi
    [[ "$_found" == "true" ]] || printf '(none)\n'
  } > "$OUTDIR/per_mount/${safe_mp}/active_procs.txt"

  # Per-operation latency table parsed from the already-collected mountstats.txt
  if [[ -s "$OUTDIR/per_mount/${safe_mp}/mountstats.txt" ]]; then
    {
      printf '## Per-operation statistics for: %s\n' "$mp"
      printf '## ops=count  avg_rtt=ms  avg_exe=ms\n'
      printf '## Only operations with ops > 0 shown\n'
      printf '%-16s %-10s %-12s %-12s\n' "Operation" "ops" "avg_rtt_ms" "avg_exe_ms"
      awk '/^[[:space:]]*per-op statistics:/{in_ops=1; next}
           in_ops && /^[[:space:]]+[A-Z0-9]+:/{
             op=$1; sub(/:/, "", op)
             ops=$2; rtt=$7; exe=$8
             if (ops+0 > 0) {
               printf "%-16s %-10d %-12.2f %-12.2f\n", op, ops, rtt/ops, exe/ops
             }
           }' "$OUTDIR/per_mount/${safe_mp}/mountstats.txt" 2>/dev/null || true
    } > "$OUTDIR/per_mount/${safe_mp}/mountstats_ops.txt"
  fi

  unset NFS_MP
done

###############################################################################
### PER-SERVER DIAGNOSTICS
###############################################################################
log "Collecting per-server network diagnostics..."

# Deduplicate servers across all mounts
declare -A SEEN_SERVERS=()
for mp in "${!MOUNTS[@]}"; do
  server="${MOUNTS[$mp]}"
  [[ -z "$server" ]] && continue
  SEEN_SERVERS["$server"]=1
done

for server in "${!SEEN_SERVERS[@]}"; do
  # Safety: validate server address before using in commands
  if ! validate_host "$server" >/dev/null; then
    continue
  fi

  safe_srv="$(slug "$server")"
  mkdir -p "$OUTDIR/per_server/${safe_srv}"

  log "  Server: $server"

  # Resolve hostname -> IPv4 if needed
  ipaddr="$server"
  if ! [[ "$server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ipaddr=$(getent ahostsv4 "$server" 2>/dev/null | awk 'NR==1{print $1}' || true)
    if [[ -z "$ipaddr" ]]; then
      log "  WARNING: could not resolve $server to IPv4"
    fi
  fi

  printf '## server: %s\n## resolved_ip: %s\n' "$server" "${ipaddr:-unresolved}" \
    > "$OUTDIR/per_server/${safe_srv}/server_info.txt"

  if [[ -n "${ipaddr:-}" ]]; then
    # Validate resolved IP too
    if ! validate_host "$ipaddr" >/dev/null; then
      continue
    fi

    run $T_FAST    "per_server/${safe_srv}/route.txt"  ip route get "$ipaddr"

    # Ping latency
    run_sh $T_NETWORK "per_server/${safe_srv}/ping.txt" \
      "ping -c $PING_COUNT -i $PING_INT $(printf '%q' "$ipaddr") 2>&1 || true"

    # NIC stats for the egress interface to this server
    dev=$(ip route get "$ipaddr" 2>/dev/null \
      | awk '/ dev /{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
      | head -n1 || true)

    if [[ -n "$dev" ]]; then
      printf '## egress_dev: %s\n' "$dev" >> "$OUTDIR/per_server/${safe_srv}/server_info.txt"
      run $T_FAST  "per_server/${safe_srv}/ip_link_dev.txt"  ip -s link show "$dev"
      if command -v ethtool >/dev/null 2>&1; then
        run $T_FAST "per_server/${safe_srv}/ethtool_S.txt"  ethtool -S "$dev"
        run $T_FAST "per_server/${safe_srv}/ethtool_i.txt"  ethtool -i "$dev"
        run $T_FAST "per_server/${safe_srv}/ethtool.txt"    ethtool "$dev"
      fi
    fi

    # NFS TCP connections specifically to this server
    run_sh $T_NORMAL "per_server/${safe_srv}/nfs_connections.txt" \
      "ss -tniop 2>/dev/null | grep -F '${ipaddr}:2049' || ss -tnop 2>/dev/null | grep -F '${ipaddr}:2049' || true"
  fi
done

fi  # end HAS_MOUNTS block (per-mount + per-server)

###############################################################################
### MISCONFIGURATION CHECKS
###############################################################################
log "Running misconfiguration checks..."

{
  printf '# NFS Client Misconfiguration Report\n'
  printf '# Generated: %s\n\n' "$(date '+%F %T')"

  pass()  { printf '[PASS] %s\n' "$*"; }
  warn()  { printf '[WARN] %s\n' "$*"; }
  fail()  { printf '[FAIL] %s\n' "$*"; }
  info()  { printf '[INFO] %s\n' "$*"; }
  section(){ printf '\n## %s\n' "$*"; }

  # --- sunrpc slot table ---
  section "sunrpc slot table"
  tcp_slots=$(sysctl -n sunrpc.tcp_slot_table_entries 2>/dev/null || echo "16")
  if [[ "$tcp_slots" -le 16 ]]; then
    warn "sunrpc.tcp_slot_table_entries=$tcp_slots (default 16 — caps parallel RPCs; consider 128-256 for throughput)"
  else
    pass "sunrpc.tcp_slot_table_entries=$tcp_slots"
  fi

  max_slots=$(sysctl -n sunrpc.max_tcp_slot_table_entries 2>/dev/null || echo "65536")
  info "sunrpc.max_tcp_slot_table_entries=$max_slots"

  # --- socket buffers ---
  section "Socket buffers"
  rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "212992")
  wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "212992")
  # Default 208KB: at 1ms RTT cap is ~200 MB/s; at 100us RTT cap is ~2 GB/s
  if [[ "$rmem_max" -lt 4194304 ]]; then
    warn "net.core.rmem_max=${rmem_max} bytes (<4MiB); may limit throughput at higher RTTs"
  else
    pass "net.core.rmem_max=${rmem_max}"
  fi
  if [[ "$wmem_max" -lt 4194304 ]]; then
    warn "net.core.wmem_max=${wmem_max} bytes (<4MiB)"
  else
    pass "net.core.wmem_max=${wmem_max}"
  fi

  if [[ "$HAS_MOUNTS" == "false" ]]; then
    info "No NFS mounts detected — mount-option checks skipped"
    info "System-level checks (slot tables, socket buffers, dirty limits) still apply"
  else
    # --- nconnect ---
    section "nconnect (multiple TCP connections per mount)"
    for mp in "${!MNTOPTS[@]}"; do
      opts="${MNTOPTS[$mp]}"
      _srv="${MOUNTS[$mp]:-}"
      if [[ "$opts" =~ nconnect=([0-9]+) ]]; then
        nc="${BASH_REMATCH[1]}"
        if [[ "$nc" -ge 2 ]]; then
          pass "nconnect=$nc for $mp"
        else
          warn "nconnect=$nc for $mp (consider nconnect=16 for VAST NFS)"
        fi
        # Check actual connections to this specific server (avoids cross-server confusion)
        if [[ -n "$_srv" ]]; then
          _srv_ip="$_srv"
          if ! [[ "$_srv" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            _srv_ip=$(getent ahostsv4 "$_srv" 2>/dev/null | awk 'NR==1{print $1}' || true)
          fi
          if [[ -n "${_srv_ip:-}" ]]; then
            _srv_conns=$(ss -tn 2>/dev/null | grep -cF "${_srv_ip}:2049" || true)
            _srv_conns="${_srv_conns:-0}"
            info "Actual ESTABLISHED connections to $_srv: $_srv_conns (nconnect=$nc configured)"
            if [[ "$_srv_conns" -lt "$nc" ]]; then
              warn "Expected ~$nc connections to $_srv (nconnect=$nc) but found $_srv_conns ESTABLISHED"
            fi
          fi
        fi
      else
        warn "nconnect not set for $mp (single TCP connection; limits parallelism)"
      fi
    done

    # --- rsize/wsize ---
    section "rsize/wsize"
    for mp in "${!MNTOPTS[@]}"; do
      opts="${MNTOPTS[$mp]}"
      if [[ "$opts" =~ rsize=([0-9]+) ]]; then
        rs="${BASH_REMATCH[1]}"
        if [[ "$rs" -ge 1048576 ]]; then pass "rsize=$rs for $mp"
        else warn "rsize=$rs for $mp (consider rsize=1048576 for VAST NFS)"; fi
      else
        info "rsize not explicitly set for $mp (kernel default applies)"
      fi
      if [[ "$opts" =~ wsize=([0-9]+) ]]; then
        ws="${BASH_REMATCH[1]}"
        if [[ "$ws" -ge 1048576 ]]; then pass "wsize=$ws for $mp"
        else warn "wsize=$ws for $mp (consider wsize=1048576 for VAST NFS)"; fi
      else
        info "wsize not explicitly set for $mp (kernel default applies)"
      fi
    done

    # --- timeo/retrans ---
    section "timeo / retrans (soft vs hard mounts)"
    for mp in "${!MNTOPTS[@]}"; do
      opts="${MNTOPTS[$mp]}"
      if [[ "$opts" =~ (^|,)soft(,|$) ]]; then
        warn "soft mount for $mp — data loss possible on server timeout; consider hard,timeo=600,retrans=3"
      elif [[ "$opts" =~ (^|,)hard(,|$) ]]; then
        pass "hard mount for $mp"
      else
        info "mount type (hard/soft) not explicit for $mp"
      fi
      if [[ "$opts" =~ (^|,)intr(,|$) ]]; then
        info "intr set for $mp (allows signal interruption of NFS ops)"
      fi
    done

    # --- actimeo / caching ---
    section "Attribute caching (actimeo)"
    for mp in "${!MNTOPTS[@]}"; do
      opts="${MNTOPTS[$mp]}"
      if [[ "$opts" =~ actimeo=([0-9]+) ]]; then
        at="${BASH_REMATCH[1]}"
        if [[ "$at" -gt 60 ]]; then
          info "actimeo=$at for $mp (high — stale data may persist longer)"
        else
          pass "actimeo=$at for $mp"
        fi
      fi
      if [[ "$opts" =~ (^|,)noac(,|$) ]]; then
        warn "noac for $mp — disables attribute caching; can cause very high metadata load"
      fi
    done

    # --- NFSv3: rpcbind running? ---
    if [[ "$HAS_NFSv3" == "true" ]]; then
      section "NFSv3: rpcbind / portmapper"
      if ss -tlnp 2>/dev/null | grep -q ':111 '; then
        pass "rpcbind listening on port 111"
      elif command -v rpcinfo >/dev/null 2>&1 && rpcinfo -p localhost >/dev/null 2>&1; then
        pass "rpcbind reachable via rpcinfo"
      else
        warn "NFSv3 mount detected but rpcbind does not appear to be listening on port 111"
      fi
    fi
  fi  # end HAS_MOUNTS mount-option checks

  # --- dirty page limits ---
  section "VM dirty page limits"
  dirty_ratio=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "20")
  dirty_bg_ratio=$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo "10")
  dirty_bytes=$(sysctl -n vm.dirty_bytes 2>/dev/null || echo "0")
  dirty_bg_bytes=$(sysctl -n vm.dirty_background_bytes 2>/dev/null || echo "0")
  if [[ "$dirty_bytes" -eq 0 && "$dirty_bg_bytes" -eq 0 ]]; then
    if [[ "$dirty_ratio" -gt 20 ]]; then
      warn "vm.dirty_ratio=$dirty_ratio (high — may cause large write bursts)"
    else
      pass "vm.dirty_ratio=$dirty_ratio vm.dirty_background_ratio=$dirty_bg_ratio"
    fi
  else
    info "vm.dirty_bytes=$dirty_bytes vm.dirty_background_bytes=$dirty_bg_bytes (explicit byte limits set)"
  fi

  printf '\n# End of misconfiguration report\n'
} > "$OUTDIR/MISCONFIG_REPORT.txt"

###############################################################################
### KUBERNETES / CSI DIAGNOSTICS
###############################################################################
log "Checking for Kubernetes environment..."

IS_K8S_NODE=false
HAS_KUBECTL=false
K8S_API_REACHABLE=false
THIS_NODE=""

# Detect if this host is a Kubernetes worker node
if [[ -d /var/lib/kubelet ]]; then
  IS_K8S_NODE=true
  log "Kubernetes node detected (/var/lib/kubelet exists)"
else
  log "Not a Kubernetes node — skipping K8s diagnostics"
fi

if [[ "$IS_K8S_NODE" == "true" ]]; then

  # ---- Node-level: no kubectl needed ----------------------------------------

  log "Collecting Kubernetes node-level data..."

  # CSI plugin sockets registered on this node
  run_sh $T_FAST "k8s/csi_plugins_dir.txt" \
    "ls -la /var/lib/kubelet/plugins/ 2>/dev/null || echo 'directory not found'"

  run_sh $T_FAST "k8s/csi_plugins_registry.txt" \
    "ls -la /var/lib/kubelet/plugins_registry/ 2>/dev/null || echo 'directory not found'"

  # NFS volumes mounted by kubelet (kubernetes.io~nfs volumes)
  run_sh $T_FAST "k8s/kubelet_nfs_volumes.txt" \
    "find /var/lib/kubelet/pods -maxdepth 4 -type d -name 'kubernetes.io~nfs' 2>/dev/null \
     | while IFS= read -r d; do echo \"=== \$d ===\"; ls \"\$d\" 2>/dev/null; done \
     || echo 'no kubelet NFS volumes found'"

  # CSI volumes mounted by kubelet (kubernetes.io~csi volumes)
  run_sh $T_FAST "k8s/kubelet_csi_volumes.txt" \
    "find /var/lib/kubelet/pods -maxdepth 4 -type d -name 'kubernetes.io~csi' 2>/dev/null \
     | while IFS= read -r d; do echo \"=== \$d ===\"; ls \"\$d\" 2>/dev/null; done \
     || echo 'no kubelet CSI volumes found'"

  # Kubelet config — may contain NFS-relevant settings
  run_sh $T_FAST "k8s/kubelet_config.txt" \
    "cat /var/lib/kubelet/config.yaml 2>/dev/null \
     || cat /var/lib/kubelet/kubeadm-flags.env 2>/dev/null \
     || echo 'kubelet config not found at standard paths'"

  # ---- kubectl availability and API reachability ----------------------------

  if command -v kubectl >/dev/null 2>&1; then
    HAS_KUBECTL=true

    # Determine kubeconfig — prefer explicit env, then default locations
    _KUBECONFIG="${KUBECONFIG:-}"
    if [[ -z "$_KUBECONFIG" ]]; then
      if [[ -f /etc/kubernetes/admin.conf ]]; then
        _KUBECONFIG=/etc/kubernetes/admin.conf
      elif [[ -f /root/.kube/config ]]; then
        _KUBECONFIG=/root/.kube/config
      elif [[ -f "$HOME/.kube/config" ]]; then
        _KUBECONFIG="$HOME/.kube/config"
      fi
    fi
    export KUBECONFIG="${_KUBECONFIG}"

    # Test API reachability with a short timeout
    if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
      K8S_API_REACHABLE=true
      log "Kubernetes API server reachable"

      # Resolve this node's name from the API
      THIS_NODE=$(kubectl get nodes -o name 2>/dev/null \
        | while IFS= read -r n; do
            nodename="${n#node/}"
            if kubectl get node "$nodename" -o jsonpath='{.status.addresses[*].address}' 2>/dev/null \
               | grep -qF "$(hostname -I | awk '{print $1}')"; then
              echo "$nodename"; break
            fi
          done || true)
      [[ -z "$THIS_NODE" ]] && THIS_NODE="$(hostname)"
      log "Resolved Kubernetes node name: $THIS_NODE"
    else
      log "WARNING: kubectl available but API server not reachable — skipping cluster-level collection"
    fi
  else
    log "kubectl not found — skipping cluster-level collection"
  fi

  # ---- Cluster-level: kubectl required --------------------------------------

  if [[ "$K8S_API_REACHABLE" == "true" ]]; then
    log "Collecting Kubernetes cluster-level data..."

    # Cluster info
    run_sh $T_NORMAL "k8s/cluster_info.txt" \
      "kubectl cluster-info --request-timeout=10s 2>&1 || true"

    # Node list and labels
    run_sh $T_NORMAL "k8s/nodes.txt" \
      "kubectl get nodes -o wide --show-labels 2>/dev/null || true"

    # This node in detail (conditions, capacity, allocatable, taints)
    run_sh $T_NORMAL "k8s/node_describe.txt" \
      "kubectl describe node $(printf '%q' "$THIS_NODE") 2>/dev/null || true"

    # Storage classes
    run_sh $T_NORMAL "k8s/storageclasses.txt" \
      "kubectl get storageclass -o wide 2>/dev/null || true"

    run_sh $T_NORMAL "k8s/storageclasses_yaml.txt" \
      "kubectl get storageclass -o yaml 2>/dev/null || true"

    # Persistent Volumes — all, with status
    run_sh $T_NORMAL "k8s/persistent_volumes.txt" \
      "kubectl get pv -o wide 2>/dev/null || true"

    run_sh $T_NORMAL "k8s/persistent_volumes_yaml.txt" \
      "kubectl get pv -o yaml 2>/dev/null || true"

    # Persistent Volume Claims — all namespaces
    run_sh $T_NORMAL "k8s/persistent_volume_claims.txt" \
      "kubectl get pvc -A -o wide 2>/dev/null || true"

    # PVs not in Bound state (Pending, Failed, Released)
    run_sh $T_NORMAL "k8s/pv_not_bound.txt" \
      "kubectl get pv 2>/dev/null | awk 'NR==1 || \$5 != \"Bound\"' || true"

    # CSI drivers registered in the cluster
    run_sh $T_NORMAL "k8s/csi_drivers.txt" \
      "kubectl get csidrivers -o wide 2>/dev/null || true"

    run_sh $T_NORMAL "k8s/csi_drivers_yaml.txt" \
      "kubectl get csidrivers -o yaml 2>/dev/null || true"

    # CSI node objects — topology keys and driver info per node
    run_sh $T_NORMAL "k8s/csi_nodes.txt" \
      "kubectl get csinode -o wide 2>/dev/null || true"

    run_sh $T_NORMAL "k8s/csi_nodes_yaml.txt" \
      "kubectl get csinode -o yaml 2>/dev/null || true"

    # This node's CSI node object in detail
    run_sh $T_NORMAL "k8s/csi_node_this.txt" \
      "kubectl describe csinode $(printf '%q' "$THIS_NODE") 2>/dev/null || true"

    # Volume attachments
    run_sh $T_NORMAL "k8s/volume_attachments.txt" \
      "kubectl get volumeattachments -o wide 2>/dev/null || true"

    # All events — NFS/volume/mount/provision related, sorted by time
    run_sh $T_LOG "k8s/events_volume.txt" \
      "kubectl get events -A --sort-by='.lastTimestamp' 2>/dev/null \
       | grep -i -E '(nfs|volume|mount|provision|attach|csi|pvc|pv)' || true"

    # All Warning events regardless of type
    run_sh $T_LOG "k8s/events_warnings.txt" \
      "kubectl get events -A --field-selector=type=Warning \
       --sort-by='.lastTimestamp' 2>/dev/null | tail -n 200 || true"

    # ---- CSI driver pods and logs -------------------------------------------

    log "Collecting CSI pod info and logs..."

    # Find all CSI-related pods across all namespaces
    run_sh $T_NORMAL "k8s/csi_pods.txt" \
      "kubectl get pods -A -o wide 2>/dev/null | grep -i csi || true"

    # Collect logs from each CSI pod (controller and node daemonset)
    kubectl get pods -A -o wide --request-timeout="${T_NORMAL}s" 2>/dev/null \
      | grep -i csi \
      | awk '{print $1, $2}' \
      | while read -r ns pod; do
          safe_pod="$(printf '%s' "${ns}__${pod}" | tr -cs 'A-Za-z0-9._-' '_')"
          mkdir -p "$OUTDIR/k8s/csi_pod_logs"

          # Pod describe
          {
            printf '## namespace: %s\n## pod: %s\n## date: %s\n' \
              "$ns" "$pod" "$(date '+%F %T')"
            "${NICE_CMD[@]}" timeout "${T_LOG}s" \
              kubectl describe pod -n "$ns" "$pod" 2>&1 || true
          } > "$OUTDIR/k8s/csi_pod_logs/${safe_pod}_describe.txt"

          # Logs per container in the pod
          containers=$(kubectl get pod -n "$ns" "$pod" \
            -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
          for container in $containers; do
            safe_c="$(printf '%s' "$container" | tr -cs 'A-Za-z0-9._-' '_')"
            {
              printf '## namespace: %s\n## pod: %s\n## container: %s\n## date: %s\n' \
                "$ns" "$pod" "$container" "$(date '+%F %T')"
              "${NICE_CMD[@]}" timeout "${T_LOG}s" \
                kubectl logs -n "$ns" "$pod" -c "$container" \
                --tail=300 2>&1 || true
            } > "$OUTDIR/k8s/csi_pod_logs/${safe_pod}_${safe_c}.txt"
          done
        done 2>/dev/null || true

    log "Kubernetes cluster-level collection complete"
  fi  # K8S_API_REACHABLE

fi  # IS_K8S_NODE

###############################################################################
### QUICKLOOK SUMMARY
###############################################################################
{
  printf '== NFS Client Support Bundle ==\n'
  printf 'Generated:  %s\n' "$(date '+%F %T')"
  printf 'Hostname:   %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'Kernel:     %s\n' "$(uname -r)"
  printf '\n'

  printf '== Detected NFS Mounts ==\n'
  if [[ "$HAS_MOUNTS" == "false" ]]; then
    printf '  (none detected — system-level diagnostics only)\n'
  else
    for mp in "${!MOUNTS[@]}"; do
      printf '  %-30s -> %s (%s)\n' "$mp" "${MOUNTS[$mp]}" "${SRCPATHS[$mp]:-N/A}"
    done
  fi
  printf '\n'

  printf '== NFS Versions ==\n'
  printf '  NFSv3: %s   NFSv4: %s\n' "$HAS_NFSv3" "$HAS_NFSv4"
  printf '\n'

  printf '== NFS TCP Connections (port 2049) ==\n'
  ss -tn 'dport = :2049' 2>/dev/null | grep 'ESTAB' || printf '  (none established)\n'
  printf '\n'

  printf '== Key sysctl ==\n'
  printf '  sunrpc.tcp_slot_table_entries = %s\n' \
    "$(sysctl -n sunrpc.tcp_slot_table_entries 2>/dev/null || echo N/A)"
  printf '  net.core.rmem_max             = %s\n' \
    "$(sysctl -n net.core.rmem_max 2>/dev/null || echo N/A)"
  printf '  net.core.wmem_max             = %s\n' \
    "$(sysctl -n net.core.wmem_max 2>/dev/null || echo N/A)"
  printf '\n'

  printf '== Misconfiguration Summary ==\n'
  grep -E '^\[(FAIL|WARN)\]' "$OUTDIR/MISCONFIG_REPORT.txt" 2>/dev/null || printf '  No FAIL/WARN items.\n'
  printf '\n'

  printf '== D-state Processes ==\n'
  dstate_count=$(ps -eo stat 2>/dev/null | grep -c '^D' || true)
  dstate_count="${dstate_count:-0}"
  printf '  Processes in D-state (uninterruptible): %s\n' "$dstate_count"
  if [[ "$dstate_count" -gt 0 ]]; then
    ps -eo pid,stat,comm,wchan 2>/dev/null | awk '$2~/^D/{print "  " $0}' || true
  fi
  printf '\n'

  printf '== Active NFS Processes ==\n'
  if [[ -s "$OUTDIR/resources/nfs_procs.txt" ]]; then
    grep -v '^##' "$OUTDIR/resources/nfs_procs.txt" 2>/dev/null \
      | head -20 | awk '{print "  " $0}' || true
  else
    printf '  (none detected or no NFS mounts)\n'
  fi
  printf '\n'

  printf '== nfsstat -c (top) ==\n'
  head -n 30 "$OUTDIR/nfs/nfsstat_client.txt" 2>/dev/null || printf '  nfsstat not available\n'
  printf '\n'

  printf '== nfsiostat sample ==\n'
  head -n 50 "$OUTDIR/performance/nfsiostat.txt" 2>/dev/null || printf '  nfsiostat not available\n'
  printf '\n'

  printf '== TCP summary ==\n'
  head -n 40 "$OUTDIR/network/netstat_s.txt" 2>/dev/null \
    || head -n 40 "$OUTDIR/sockets/ss_summary.txt" 2>/dev/null \
    || printf '  ss/netstat summary not available\n'
  printf '\n'

  printf '== Kubernetes / CSI ==\n'
  if [[ "$IS_K8S_NODE" == "false" ]]; then
    printf '  Not a Kubernetes node\n'
  else
    printf '  Kubernetes node:    yes\n'
    printf '  kubectl available:  %s\n' "$HAS_KUBECTL"
    printf '  API reachable:      %s\n' "$K8S_API_REACHABLE"
    printf '  Node name:          %s\n' "${THIS_NODE:-unknown}"
    printf '\n'
    printf '  CSI plugins registered on node:\n'
    ls /var/lib/kubelet/plugins/ 2>/dev/null \
      | awk '{print "    " $0}' \
      || printf '    (none or directory missing)\n'
    printf '\n'
    if [[ "$K8S_API_REACHABLE" == "true" ]]; then
      printf '  Storage classes:\n'
      kubectl get storageclass --no-headers 2>/dev/null \
        | awk '{print "    " $0}' \
        || printf '    (none)\n'
      printf '\n'
      printf '  PVs not Bound:\n'
      kubectl get pv --no-headers 2>/dev/null \
        | awk '$5 != "Bound" {print "    " $0}' \
        || printf '    (all bound or no PVs)\n'
      printf '\n'
      printf '  Recent volume/NFS warnings:\n'
      grep -i -E '(nfs|volume|mount|provision|csi)' \
        "$OUTDIR/k8s/events_warnings.txt" 2>/dev/null \
        | tail -n 10 \
        | awk '{print "    " $0}' \
        || printf '    (none)\n'
    fi
  fi
} > "$OUTDIR/QUICKLOOK.txt"

###############################################################################
### PACKET CAPTURE + FIO BENCHMARK  (only if --with-fio was passed)
###############################################################################
if [[ -n "$FIO_MOUNT" ]]; then

  # --- Resolve NFS interface for tcpdump (capture runs during first fio test) ---
  _nfs_iface="any"
  _tcpdump_pid=""
  if command -v tcpdump >/dev/null 2>&1; then
    _nfs_server="${MOUNTS[$FIO_MOUNT]:-}"
    if [[ -n "$_nfs_server" ]]; then
      _nfs_server_ip="$_nfs_server"
      if ! [[ "$_nfs_server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _nfs_server_ip=$(getent ahostsv4 "$_nfs_server" 2>/dev/null \
          | awk 'NR==1{print $1}' || true)
      fi
      if [[ -n "${_nfs_server_ip:-}" ]]; then
        _nfs_iface=$(ip route get "$_nfs_server_ip" 2>/dev/null \
          | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}' || true)
      fi
    fi
    _nfs_iface="${_nfs_iface:-any}"
    log "tcpdump ready — will capture on ${_nfs_iface} during seq-write-128k"
  else
    log "tcpdump not installed — skipping packet capture"
  fi

  # --- fio benchmark ---
  log "Running fio benchmark on $FIO_MOUNT ..."

  if ! command -v fio >/dev/null 2>&1; then
    log "WARNING: fio not installed — skipping benchmark"
    printf 'fio not installed on this system\n' \
      > "$OUTDIR/performance/fio_results.txt"
  else
    FIO_RUNTIME=30
    FIO_SIZE="2g"
    FIO_NUMJOBS=4

    FIO_TESTDIR=""

    _fio_cleanup() {
      if [[ -n "$FIO_TESTDIR" && -d "$FIO_TESTDIR" && \
            "$FIO_TESTDIR" == "$FIO_MOUNT"/* ]]; then
        rm -rf "$FIO_TESTDIR" 2>/dev/null || true
      fi
    }
    trap '_fio_cleanup' EXIT INT TERM

    FIO_TESTDIR="$(mktemp -d -p "$FIO_MOUNT" fio_test.XXXXXX 2>/dev/null)" || {
      log "ERROR: Failed to create temporary fio test directory under $FIO_MOUNT"
      printf 'Failed to create temporary fio test directory\n' \
        > "$OUTDIR/performance/fio_results.txt"
      FIO_TESTDIR=""
    }

    _fio_job() {
      local name="$1"; shift
      printf '\n================================================================\n'
      printf ' %s\n' "$name"
      printf '================================================================\n'
      fio --name="$name" \
          --directory="$FIO_TESTDIR" \
          --size="$FIO_SIZE" \
          --runtime="$FIO_RUNTIME" \
          --time_based \
          --numjobs="$FIO_NUMJOBS" \
          --group_reporting \
          --output-format=normal \
          "$@"
    }

    if [[ -n "$FIO_TESTDIR" ]]; then
      {
        printf '## fio benchmark\n'
        printf '## mount      : %s\n' "$FIO_MOUNT"
        printf '## size/job   : %s\n' "$FIO_SIZE"
        printf '## jobs       : %s\n' "$FIO_NUMJOBS"
        printf '## runtime    : %ss per test\n' "$FIO_RUNTIME"
        printf '## started    : %s\n\n' "$(date '+%F %T')"
        printf 'NOTE: NFS does not support O_DIRECT. Using libaio engine for iodepth > 1.\n'
        printf '      Results reflect page-cache-assisted I/O flushed via fsync.\n'

        # 1. Sequential write — throughput (packet capture runs concurrently)
        if command -v tcpdump >/dev/null 2>&1; then
          tcpdump -i "$_nfs_iface" \
            -w "$OUTDIR/performance/nfs_packets.pcap" \
            -n --snapshot-length=128 -c 500000 \
            'port 2049' >/dev/null 2>&1 &
          _tcpdump_pid=$!
          printf '## packet capture started on %s (pid=%s)\n' "$_nfs_iface" "$_tcpdump_pid"
        fi
        _fio_job "seq-write-128k" \
          --rw=write --bs=128k --iodepth=16 --ioengine=libaio --end_fsync=1
        if [[ -n "${_tcpdump_pid:-}" ]]; then
          kill "$_tcpdump_pid" 2>/dev/null || true
          wait "$_tcpdump_pid" 2>/dev/null || true
          _tcpdump_pid=""
          printf '## packet capture stopped — performance/nfs_packets.pcap\n'
        fi

        # 2. Sequential read — throughput
        _fio_job "seq-read-128k" \
          --rw=read --bs=128k --iodepth=16 --ioengine=libaio

        # 3. Random write — IOPS / latency
        _fio_job "rand-write-4k" \
          --rw=randwrite --bs=4k --iodepth=32 --ioengine=libaio --fsync=1

        # 4. Mixed random 70/30 — realistic workload
        _fio_job "mixed-rand-70r30w-4k" \
          --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --ioengine=libaio --fsync=8

        printf '\n## finished: %s\n' "$(date '+%F %T')"
      } > "$OUTDIR/performance/fio_results.txt" 2>&1 || true

      _fio_cleanup
      log "fio benchmark complete — results in performance/fio_results.txt"
    fi
    trap - EXIT INT TERM
  fi
fi

###############################################################################
### BUNDLE & CLEANUP
###############################################################################
TARFILE="${OUTDIR}.tar.gz"
printf '%s Bundling %s\n' "$(date '+%F %T')" "$TARFILE" >> "$OUTDIR/_collector.log"
tar -czf "$TARFILE" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")"
chmod 600 "$TARFILE"

if tar -tzf "$TARFILE" >/dev/null 2>&1; then
  rm -rf "$OUTDIR"
  # If run via sudo, give ownership back to the invoking user so they can scp
  # without needing root. Permissions stay 600 (no world-read).
  if [[ -n "$_INVOKE_USER" ]]; then
    chown "$_INVOKE_USER" "$TARFILE" 2>/dev/null || true
  fi
  echo "$TARFILE"
else
  echo "WARNING: tar verification failed — leaving $OUTDIR for inspection." >&2
fi
