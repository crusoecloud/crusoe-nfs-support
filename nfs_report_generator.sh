#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# NFS Diagnostics HTML Report Generator
#
# WHAT IT DOES:
#   Transforms the output of nfs_client_support_bundle.sh into an interactive
#   HTML report with collapsible sections, table of contents, colored
#   misconfiguration report, and per-mount / per-server detail views.
#
# USAGE:
#   ./nfs_report_generator.sh <diagnostics_directory_or_tarball>
#
# EXAMPLE:
#   ./nfs_report_generator.sh nfs_client_collect_20251016_120000.tar.gz
#   ./nfs_report_generator.sh nfs_client_collect_20251016_120000/
#
# OUTPUT:
#   Creates: <diagnostics_directory>/index.html
#   Open in browser: open index.html  (macOS)  /  xdg-open index.html  (Linux)
#
# DIRECTORY STRUCTURE EXPECTED:
#   <datadir>/
#     QUICKLOOK.txt
#     MISCONFIG_REPORT.txt
#     system/         uname, hostname, packages, sysctl, modules
#     nfs/            nfsstat, mountstats, proc/net/rpc, NFSv3/v4 specific
#     sockets/        ss, /proc/net/snmp, socket buffer config, sunrpc
#     network/        ip link/addr/route, netstat
#     performance/    nfsiostat, iostat, mpstat, vmstat, fio_results (optional)
#     logs/           kernel_journal, dmesg, nfs_journal_entries
#     storage/        lsblk, df, dmesg block errors
#     resources/      free, meminfo, loadavg, top, ps_cpu, ps_mem, d-state procs,
#                     nfs_procs, nfs_proc_io
#     per_mount/<mp>/ df, mountstats, mount_opts, nfsstat_m,
#                     active_procs, mountstats_ops
#     per_server/<s>/ server_info, route, ping, ethtool, nfs_connections
#
###############################################################################

# Check arguments
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <diagnostics_directory_or_tarball>"
  echo ""
  echo "Examples:"
  echo "  $0 nfs_client_collect_20251016_120000.tar.gz"
  echo "  $0 nfs_client_collect_20251016_120000/"
  exit 1
fi

INPUT="${1%/}"
_EXTRACTED_DIR=""  # track if we extracted, so we can clean up

if [[ -f "$INPUT" ]] && file "$INPUT" 2>/dev/null | grep -qiE 'gzip|tar'; then
  # Input is a tarball — extract to a temp directory alongside it
  _EXTRACT_BASE="$(dirname "$INPUT")"
  echo "Extracting $INPUT ..."
  tar -xzf "$INPUT" -C "$_EXTRACT_BASE"
  # Track the top-level extracted entry for cleanup (handles both bare and path-prefixed tarballs)
  _top_entry=$(tar -tzf "$INPUT" 2>/dev/null | head -n1 | cut -d/ -f1)
  _EXTRACTED_DIR="$_EXTRACT_BASE/${_top_entry}"
  # Find the nfs_client_collect_* directory regardless of how deep it was packed
  DATADIR=$(find "$_EXTRACT_BASE" -maxdepth 8 -type d -name "nfs_client_collect_*" 2>/dev/null \
    | sort | head -n1)
  if [[ ! -d "${DATADIR:-}" ]]; then
    echo "ERROR: could not find nfs_client_collect_* directory in '$INPUT'" >&2
    exit 1
  fi
elif [[ -d "$INPUT" ]]; then
  DATADIR="$INPUT"
else
  echo "ERROR: '$INPUT' is neither a directory nor a recognisable tar.gz file."
  exit 1
fi

INDEX_HTML="$DATADIR/index.html"
echo "Generating HTML report from: $DATADIR"

# =================== HTML helpers ===================
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# html_section <id> <title> <filepath> [open|closed]
html_section() {
  local id="$1" title="$2" file="$3" state="${4:-open}"
  printf '<section id="%s">\n' "$id"
  printf '  <h2>%s <a class="tiny" href="#top" title="Back to top">&#8593;</a></h2>\n' "$title"
  printf '  <details %s><summary>show/hide</summary><pre>\n' "$state"
  if [[ -s "$file" ]]; then html_escape < "$file"; else printf '(empty or not available)\n'; fi
  printf '  </pre></details>\n</section>\n'
}

# html_subsection <id> <title> <filepath> [open|closed]
html_subsection() {
  local id="$1" title="$2" file="$3" state="${4:-open}"
  if [[ ! -s "$file" ]]; then return; fi
  printf '<div id="%s">\n  <h3>%s</h3>\n' "$id" "$title"
  printf '  <details %s><summary>show/hide</summary><pre>\n' "$state"
  html_escape < "$file"
  printf '  </pre></details>\n</div>\n'
}

# Render MISCONFIG_REPORT.txt with PASS/WARN/FAIL colorization
html_misconfig() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    echo "<p>(Misconfiguration report not available)</p>"
    return
  fi
  echo "<pre class='misconfig'>"
  while IFS= read -r line; do
    escaped=$(printf '%s' "$line" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    case "$line" in
      '[FAIL]'*)  printf '<span class="mc-fail">%s</span>\n' "$escaped" ;;
      '[WARN]'*)  printf '<span class="mc-warn">%s</span>\n' "$escaped" ;;
      '[PASS]'*)  printf '<span class="mc-pass">%s</span>\n' "$escaped" ;;
      '[INFO]'*)  printf '<span class="mc-info">%s</span>\n' "$escaped" ;;
      '#'*)       printf '<span class="mc-head">%s</span>\n' "$escaped" ;;
      *)          printf '%s\n' "$escaped" ;;
    esac
  done < "$file"
  echo "</pre>"
}

# =================== CSS ===================
NAV_CSS='
  body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; margin:24px; line-height:1.4; max-width:1400px;}
  h1{margin:0 0 8px;}
  h2{margin:20px 0 8px; font-size:1.1rem}
  h3{margin:14px 0 6px; font-size:1.0rem; color:#333}
  .meta{color:#555; margin-bottom:16px}
  details{margin:6px 0 16px}
  summary{cursor:pointer; color:#0366d6}
  pre{background:#0b1020; color:#d5d7e2; padding:12px; border-radius:8px; overflow:auto; font-size:12px; line-height:1.5}
  pre.misconfig{background:#1a1a2e; color:#d5d7e2;}
  .mc-fail{color:#ff6b6b; font-weight:bold}
  .mc-warn{color:#ffa94d; font-weight:bold}
  .mc-pass{color:#69db7c}
  .mc-info{color:#74c0fc}
  .mc-head{color:#e9ecef; font-weight:bold; font-size:1.05em}
  code{background:#f6f8fa; padding:2px 4px; border-radius:4px}
  .grid{display:grid; gap:12px}
  .cols-2{grid-template-columns: repeat(auto-fit, minmax(340px,1fr));}
  .cols-3{grid-template-columns: repeat(auto-fit, minmax(280px,1fr));}
  .pill{display:inline-block; background:#eef6ff; color:#0353a4; padding:2px 8px; border-radius:999px; font-size:12px; margin-right:6px}
  .pill-warn{background:#fff3bf; color:#7c4700}
  .pill-fail{background:#ffe3e3; color:#c92a2a}
  .pill-pass{background:#d3f9d8; color:#1b5e20}
  .card{border:1px solid #e5e7eb; border-radius:10px; padding:12px; margin-bottom:16px}
  .card-warn{border-color:#ffa94d; background:#fff8f0}
  .small{font-size:12px; color:#666}
  a{color:#0366d6; text-decoration:none}
  a:hover{text-decoration:underline}
  .toc a{display:inline-block; margin:2px 8px 2px 0}
  .tiny{font-size:.8rem; margin-left:.25rem; text-decoration:none}
  .toc{border:1px solid #e5e7eb; border-radius:10px; padding:12px; margin:12px 0}
  .badge{display:inline-block;padding:2px 7px;border-radius:999px;font-size:11px;font-weight:bold;margin-left:6px}
  .badge-v3{background:#d0ebff;color:#1864ab}
  .badge-v4{background:#e5dbff;color:#4a1e9e}
  .sect-divider{border:none;border-top:1px solid #e5e7eb;margin:24px 0}
'

# =================== Discover mounts ===================
mount_dirs=()
mount_labels=()

if [[ -d "$DATADIR/per_mount" ]]; then
  for d in "$DATADIR/per_mount"/*/; do
    [[ -d "$d" ]] || continue
    safe_mp="$(basename "$d")"
    # Read authoritative path from mount_opts.txt header (slug reversal is lossy)
    mp="$safe_mp"
    if [[ -s "$DATADIR/per_mount/${safe_mp}/mount_opts.txt" ]]; then
      _hdr=$(head -n1 "$DATADIR/per_mount/${safe_mp}/mount_opts.txt" 2>/dev/null || true)
      if [[ "$_hdr" == "## Mount options for: "* ]]; then
        mp="${_hdr#'## Mount options for: '}"
      fi
    fi
    mount_dirs+=("$safe_mp")
    mount_labels+=("$mp")
  done
fi
mount_count=${#mount_dirs[@]}

# =================== Discover servers ===================
server_dirs=()
server_labels=()

if [[ -d "$DATADIR/per_server" ]]; then
  for d in "$DATADIR/per_server"/*/; do
    [[ -d "$d" ]] || continue
    safe_srv="$(basename "$d")"
    server_dirs+=("$safe_srv")
    server_labels+=("$safe_srv")
  done
fi
server_count=${#server_dirs[@]}

# =================== Detect NFS versions from collected data ===================
HAS_V3=false
HAS_V4=false
if [[ -s "$DATADIR/nfs/nfsv3_ports.txt" || -s "$DATADIR/nfs/rpcinfo_p.txt" ]]; then
  HAS_V3=true
fi
if grep -qE 'nfs4' "$DATADIR/nfs/proc_mounts.txt" 2>/dev/null; then
  HAS_V4=true
fi
if grep -qE ' nfs ' "$DATADIR/nfs/proc_mounts.txt" 2>/dev/null; then
  HAS_V3=true
fi
# Also check nfsstat -m output for vers=
if [[ -s "$DATADIR/nfs/nfsstat_m.txt" ]]; then
  grep -q 'vers=3' "$DATADIR/nfs/nfsstat_m.txt" 2>/dev/null && HAS_V3=true
  grep -q 'vers=4' "$DATADIR/nfs/nfsstat_m.txt" 2>/dev/null && HAS_V4=true
fi


# =================== Generate HTML ===================
{
  echo "<!doctype html><html><head><meta charset='utf-8'/>"
  echo "<title>NFS Client Diagnostics Report — $(basename "$DATADIR")</title>"
  echo "<style>${NAV_CSS}</style>"
  echo "</head><body>"
  echo "<a id='top'></a>"
  echo "<h1>NFS Client Diagnostics Report</h1>"
  printf "<div class='meta'>"
  printf "Generated: %s &nbsp;•&nbsp; " "$(date '+%F %T')"
  printf "Source: <code>%s</code>" "$(basename "$DATADIR")"
  [[ "$HAS_V3" == "true" ]] && printf " &nbsp;<span class='badge badge-v3'>NFSv3</span>"
  [[ "$HAS_V4" == "true" ]] && printf " &nbsp;<span class='badge badge-v4'>NFSv4</span>"
  printf "</div>\n"


  # Table of Contents
  echo "<div class='toc'><b>Table of Contents</b><br/>"
  echo "<a href='#detected-mounts'>Detected NFS Mounts</a>"
  [[ -s "$DATADIR/QUICKLOOK.txt" ]]          && echo "<a href='#quick-look'>Quick Look</a>"
  [[ -s "$DATADIR/MISCONFIG_REPORT.txt" ]]   && echo "<a href='#misconfig'>Misconfiguration Report</a>"
  echo "<a href='#nfs-stats'>NFS Client Stats</a>"
  [[ "$HAS_V3" == "true" ]]                  && echo "<a href='#nfsv3'>NFSv3 Diagnostics</a>"
  [[ "$HAS_V4" == "true" ]]                  && echo "<a href='#nfsv4'>NFSv4 Diagnostics</a>"
  echo "<a href='#sockets'>Socket Diagnostics</a>"
  echo "<a href='#kernel-logs'>Kernel Logs</a>"
  echo "<a href='#performance'>System Load &amp; Performance</a>"
  echo "<a href='#network'>Network</a>"
  echo "<a href='#storage'>Storage &amp; Block Devices</a>"
  echo "<a href='#resources'>System Resources</a>"
  [[ $mount_count -gt 0 ]]                   && echo "<a href='#per-mount'>Per-Mount Details</a>"
  [[ $server_count -gt 0 ]]                  && echo "<a href='#per-server'>Per-Server Details</a>"
  echo "<a href='#system-context'>System Context</a>"
  echo "</div>"

  # ---- Detected Mounts ----
  echo "<section id='detected-mounts' class='card'>"
  echo "<h2>Detected NFS Mounts <a class='tiny' href='#top'>↑</a></h2>"
  if [[ $mount_count -gt 0 ]]; then
    echo "<ul>"
    for i in $(seq 0 $((mount_count - 1))); do
      safe_mp="${mount_dirs[$i]}"
      mp="${mount_labels[$i]}"
      # Try to get server from per_mount/safe_mp/mount_opts.txt or server_info
      src="N/A"
      if [[ -s "$DATADIR/per_mount/${safe_mp}/mount_opts.txt" ]]; then
        src=$(grep -v '^##' "$DATADIR/per_mount/${safe_mp}/mount_opts.txt" 2>/dev/null | head -n1 || echo "N/A")
      fi
      echo "<li><span class='pill'>mount</span>"
      echo "<b><a href='#mount-${safe_mp}'>${mp}</a></b>"
      [[ "$src" != "N/A" && -n "$src" ]] && printf " &nbsp;<span class='small'>opts: %s</span>" "$(printf '%s' "$src" | html_escape)"
      echo "</li>"
    done
    echo "</ul>"
  else
    echo "<p>No per-mount directories found in diagnostics.</p>"
    # Fallback: show proc_mounts if available
    if [[ -s "$DATADIR/nfs/proc_mounts.txt" ]]; then
      echo "<pre>"
      html_escape < "$DATADIR/nfs/proc_mounts.txt"
      echo "</pre>"
    fi
  fi
  echo "</section>"

  # ---- Quick Look ----
  if [[ -s "$DATADIR/QUICKLOOK.txt" ]]; then
    echo "<section id='quick-look' class='card'>"
    echo "<h2>Quick Look <a class='tiny' href='#top'>↑</a></h2><pre>"
    html_escape < "$DATADIR/QUICKLOOK.txt"
    echo "</pre></section>"
  fi

  # ---- Misconfiguration Report ----
  if [[ -s "$DATADIR/MISCONFIG_REPORT.txt" ]]; then
    echo "<section id='misconfig' class='card'>"
    echo "<h2>Misconfiguration Report <a class='tiny' href='#top'>↑</a></h2>"
    html_misconfig "$DATADIR/MISCONFIG_REPORT.txt"
    echo "</section>"
  fi

  echo "<hr class='sect-divider'/>"

  # ---- NFS Client Stats ----
  echo "<section id='nfs-stats'><h2>NFS Client Stats <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  [[ -s "$DATADIR/nfs/nfsstat_m.txt" ]]          && html_section 'nfsstat-m'        'nfsstat -m (mounts)'           "$DATADIR/nfs/nfsstat_m.txt"
  [[ -s "$DATADIR/nfs/nfsstat_client.txt" ]]      && html_section 'nfsstat-c'        'nfsstat -c (client ops)'       "$DATADIR/nfs/nfsstat_client.txt"
  [[ -s "$DATADIR/nfs/nfsstat_rpc.txt" ]]         && html_section 'nfsstat-r'        'nfsstat -r (RPC)'              "$DATADIR/nfs/nfsstat_rpc.txt"
  [[ -s "$DATADIR/nfs/nfsstat_net.txt" ]]         && html_section 'nfsstat-n'        'nfsstat -n (network)'          "$DATADIR/nfs/nfsstat_net.txt"
  [[ -s "$DATADIR/nfs/proc_net_rpc_nfs.txt" ]]    && html_section 'proc-rpc-nfs'     '/proc/net/rpc/nfs'             "$DATADIR/nfs/proc_net_rpc_nfs.txt"
  [[ -s "$DATADIR/nfs/proc_net_rpc_nfsd.txt" ]]   && html_section 'proc-rpc-nfsd'    '/proc/net/rpc/nfsd'            "$DATADIR/nfs/proc_net_rpc_nfsd.txt"
  [[ -s "$DATADIR/nfs/mounts.txt" ]]              && html_section 'mounts'           'mount -t nfs,nfs4'             "$DATADIR/nfs/mounts.txt"
  [[ -s "$DATADIR/nfs/proc_mounts.txt" ]]         && html_section 'proc-mounts'      '/proc/mounts (nfs entries)'    "$DATADIR/nfs/proc_mounts.txt"
  [[ -s "$DATADIR/nfs/proc_mountstats.txt" ]]     && html_section 'proc-mountstats'  '/proc/self/mountstats'         "$DATADIR/nfs/proc_mountstats.txt" "closed"
  [[ -s "$DATADIR/nfs/mountstats_summary.txt" ]]  && html_section 'mountstats-sum'   'mountstats'                    "$DATADIR/nfs/mountstats_summary.txt"
  [[ -s "$DATADIR/nfs/fstab_nfs.txt" ]]           && html_section 'fstab-nfs'        '/etc/fstab (nfs entries)'      "$DATADIR/nfs/fstab_nfs.txt"
  echo "</div></section>"

  # ---- NFSv3 Diagnostics ----
  if [[ "$HAS_V3" == "true" ]]; then
    echo "<section id='nfsv3'><h2>NFSv3 Diagnostics <span class='badge badge-v3'>v3</span> <a class='tiny' href='#top'>↑</a></h2>"
    echo "<div class='grid cols-2'>"
    [[ -s "$DATADIR/nfs/rpcinfo_p.txt" ]]         && html_section 'rpcinfo-p'     'rpcinfo -p localhost'           "$DATADIR/nfs/rpcinfo_p.txt"
    [[ -s "$DATADIR/nfs/rpcinfo_s.txt" ]]         && html_section 'rpcinfo-s'     'rpcinfo -s localhost'           "$DATADIR/nfs/rpcinfo_s.txt"
    [[ -s "$DATADIR/nfs/nfsv3_ports.txt" ]]       && html_section 'nfsv3-ports'   'NFSv3 port check (111/2049)'    "$DATADIR/nfs/nfsv3_ports.txt"
    [[ -s "$DATADIR/nfs/rpcbind_status.txt" ]]    && html_section 'rpcbind-status' 'rpcbind / statd status'        "$DATADIR/nfs/rpcbind_status.txt"
    [[ -s "$DATADIR/nfs/lockd_params.txt" ]]      && html_section 'lockd-params'  'lockd parameters'               "$DATADIR/nfs/lockd_params.txt"
    echo "</div></section>"
  fi

  # ---- NFSv4 Diagnostics ----
  if [[ "$HAS_V4" == "true" ]]; then
    echo "<section id='nfsv4'><h2>NFSv4 Diagnostics <span class='badge badge-v4'>v4</span> <a class='tiny' href='#top'>↑</a></h2>"
    echo "<div class='grid cols-2'>"
    [[ -s "$DATADIR/nfs/nfsv4_idmapd_status.txt" ]] && html_section 'idmapd-status' 'idmapd service status'       "$DATADIR/nfs/nfsv4_idmapd_status.txt"
    [[ -s "$DATADIR/nfs/nfsv4_idmapd_conf.txt" ]]   && html_section 'idmapd-conf'   '/etc/idmapd.conf'            "$DATADIR/nfs/nfsv4_idmapd_conf.txt"
    [[ -s "$DATADIR/nfs/nfsv4_lease.txt" ]]          && html_section 'nfsv4-lease'   '/proc/fs/nfsfs/servers'      "$DATADIR/nfs/nfsv4_lease.txt"
    [[ -s "$DATADIR/nfs/nfsv4_sessions.txt" ]]       && html_section 'nfsv4-sessions' '/proc/fs/nfsfs (sessions)'  "$DATADIR/nfs/nfsv4_sessions.txt"
    echo "</div></section>"
  fi

  echo "<hr class='sect-divider'/>"

  # ---- Socket Diagnostics ----
  echo "<section id='sockets'><h2>Socket Diagnostics <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  [[ -s "$DATADIR/sockets/socket_buffer_config.txt" ]] && html_section 'sock-buf'        'Socket buffer config &amp; NFS connections' "$DATADIR/sockets/socket_buffer_config.txt"
  [[ -s "$DATADIR/sockets/ss_nfs_connections.txt" ]]   && html_section 'ss-nfs'          'ss -tniop dport=2049'                       "$DATADIR/sockets/ss_nfs_connections.txt"
  [[ -s "$DATADIR/sockets/sunrpc_stats.txt" ]]         && html_section 'sunrpc-stats'    'sunrpc slot tables &amp; stats'             "$DATADIR/sockets/sunrpc_stats.txt"
  [[ -s "$DATADIR/sockets/proc_net_snmp.txt" ]]        && html_section 'proc-snmp'       '/proc/net/snmp (TCP/IP counters)'           "$DATADIR/sockets/proc_net_snmp.txt"
  [[ -s "$DATADIR/sockets/proc_net_netstat.txt" ]]     && html_section 'proc-netstat'    '/proc/net/netstat (extended TCP counters)'  "$DATADIR/sockets/proc_net_netstat.txt" "closed"
  [[ -s "$DATADIR/sockets/ss_tni.txt" ]]               && html_section 'ss-tni'          'ss -tni (all TCP detail)'                   "$DATADIR/sockets/ss_tni.txt" "closed"
  [[ -s "$DATADIR/sockets/ss_summary.txt" ]]           && html_section 'ss-summary'      'ss -s (summary)'                           "$DATADIR/sockets/ss_summary.txt"
  [[ -s "$DATADIR/sockets/ss_unix_rpc.txt" ]]          && html_section 'ss-unix-rpc'     'Unix sockets (RPC)'                        "$DATADIR/sockets/ss_unix_rpc.txt"
  echo "</div></section>"

  # ---- Kernel Logs ----
  echo "<section id='kernel-logs'><h2>Kernel Logs <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  if [[ -s "$DATADIR/logs/nfs_journal_entries.txt" ]]; then
    html_section 'nfs-journal'     'NFS/RPC kernel log entries'     "$DATADIR/logs/nfs_journal_entries.txt"
  fi
  if [[ -s "$DATADIR/logs/kernel_journal.txt" ]]; then
    html_section 'kernel-journal'  'Full kernel journal (tail)'     "$DATADIR/logs/kernel_journal.txt" "closed"
  elif [[ -s "$DATADIR/logs/dmesg.txt" ]]; then
    html_section 'dmesg'           'dmesg (tail)'                   "$DATADIR/logs/dmesg.txt" "closed"
  fi
  if [[ -s "$DATADIR/logs/dmesg_nfs.txt" ]]; then
    html_section 'dmesg-nfs'       'dmesg NFS/RPC entries'          "$DATADIR/logs/dmesg_nfs.txt"
  fi
  echo "</div></section>"

  echo "<hr class='sect-divider'/>"

  # ---- Performance ----
  echo "<section id='performance'><h2>System Load &amp; Performance <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  [[ -s "$DATADIR/performance/nfsiostat.txt" ]]   && html_section 'nfsiostat'   'nfsiostat sample'              "$DATADIR/performance/nfsiostat.txt"
  [[ -s "$DATADIR/performance/iostat_x.txt" ]]    && html_section 'iostat-x'    'iostat -x sample'              "$DATADIR/performance/iostat_x.txt"
  [[ -s "$DATADIR/performance/mpstat.txt" ]]      && html_section 'mpstat'      'mpstat sample'                 "$DATADIR/performance/mpstat.txt"
  [[ -s "$DATADIR/performance/vmstat.txt" ]]      && html_section 'vmstat'      'vmstat sample'                 "$DATADIR/performance/vmstat.txt"
  [[ -s "$DATADIR/performance/fio_results.txt" ]] && html_section 'fio-results' 'fio benchmark results'         "$DATADIR/performance/fio_results.txt"
  echo "</div></section>"

  # ---- Network ----
  echo "<section id='network'><h2>Network <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  [[ -s "$DATADIR/network/netstat_s.txt" ]]    && html_section 'netstat-s'    'netstat -s'          "$DATADIR/network/netstat_s.txt"
  [[ -s "$DATADIR/network/ip_link_stats.txt" ]] && html_section 'ip-link'     'ip -s link'          "$DATADIR/network/ip_link_stats.txt"
  [[ -s "$DATADIR/network/ip_addr.txt" ]]       && html_section 'ip-addr'     'ip addr show'        "$DATADIR/network/ip_addr.txt"
  [[ -s "$DATADIR/network/ip_route.txt" ]]      && html_section 'ip-route'    'ip route show'       "$DATADIR/network/ip_route.txt"
  echo "</div></section>"

  # ---- Storage / Block Devices ----
  echo "<section id='storage'><h2>Storage &amp; Block Devices (VM) <a class='tiny' href='#top'>↑</a></h2>"
  echo "<p class='small'>Block devices as seen from inside the VM (<code>/dev/sda</code>, <code>/dev/sdb</code>, etc.)</p>"
  echo "<div class='grid cols-2'>"
  [[ -s "$DATADIR/storage/lsblk.txt" ]]               && html_section 'lsblk'         'lsblk'                      "$DATADIR/storage/lsblk.txt"
  [[ -s "$DATADIR/storage/df_all.txt" ]]               && html_section 'df-all'        'df -hT (all filesystems)'   "$DATADIR/storage/df_all.txt"
  [[ -s "$DATADIR/storage/dmesg_block_errors.txt" ]]   && html_section 'blk-errors'    'dmesg block device errors'  "$DATADIR/storage/dmesg_block_errors.txt"
  echo "</div></section>"

  # ---- Resources ----
  echo "<section id='resources'><h2>System Resources <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  [[ -s "$DATADIR/resources/top.txt" ]]           && html_section 'top'           'top -b -n 1 (snapshot)'    "$DATADIR/resources/top.txt"
  [[ -s "$DATADIR/resources/free.txt" ]]          && html_section 'mem-free'      'free -h'                   "$DATADIR/resources/free.txt"
  [[ -s "$DATADIR/resources/proc_loadavg.txt" ]]  && html_section 'loadavg'       '/proc/loadavg'             "$DATADIR/resources/proc_loadavg.txt"
  [[ -s "$DATADIR/resources/dstate_procs.txt" ]]  && html_section 'dstate-procs'  'D-state processes (I/O blocked)' "$DATADIR/resources/dstate_procs.txt"
  [[ -s "$DATADIR/resources/nfs_procs.txt" ]]     && html_section 'nfs-procs'     'NFS open-file processes'   "$DATADIR/resources/nfs_procs.txt"
  [[ -s "$DATADIR/resources/nfs_proc_io.txt" ]]   && html_section 'nfs-proc-io'   '/proc/pid/io for NFS procs' "$DATADIR/resources/nfs_proc_io.txt"
  [[ -s "$DATADIR/resources/ps_cpu.txt" ]]        && html_section 'ps-cpu'        'ps by CPU usage (top 60)'  "$DATADIR/resources/ps_cpu.txt"
  [[ -s "$DATADIR/resources/ps_mem.txt" ]]        && html_section 'ps-mem'        'ps by memory usage (top 60)' "$DATADIR/resources/ps_mem.txt"
  [[ -s "$DATADIR/resources/proc_vmstat.txt" ]]   && html_section 'proc-vmstat'   '/proc/vmstat (dirty/swap)'  "$DATADIR/resources/proc_vmstat.txt"
  [[ -s "$DATADIR/resources/proc_meminfo.txt" ]]  && html_section 'meminfo'       '/proc/meminfo'             "$DATADIR/resources/proc_meminfo.txt" "closed"
  echo "</div></section>"

  echo "<hr class='sect-divider'/>"

  # ---- Per-Mount Details ----
  if [[ $mount_count -gt 0 ]]; then
    echo "<section id='per-mount'><h2>Per-Mount Details <a class='tiny' href='#top'>↑</a></h2>"
    echo "<div class='toc small'>"
    for i in $(seq 0 $((mount_count - 1))); do
      safe_mp="${mount_dirs[$i]}"
      mp="${mount_labels[$i]}"
      echo "<a href='#mount-${safe_mp}'>${mp}</a>"
    done
    echo "</div>"

    for i in $(seq 0 $((mount_count - 1))); do
      safe_mp="${mount_dirs[$i]}"
      mp="${mount_labels[$i]}"
      mdir="$DATADIR/per_mount/${safe_mp}"

      echo "<div class='card' id='mount-${safe_mp}'>"
      echo "<h3>${mp} <a class='tiny' href='#per-mount'>↑ mounts</a></h3>"

      echo "<div class='grid cols-2'>"
      [[ -s "$mdir/mount_opts.txt" ]]    && html_section "opts-${safe_mp}"         "Mount options: ${mp}"            "$mdir/mount_opts.txt"
      [[ -s "$mdir/df.txt" ]]            && html_section "df-${safe_mp}"           "df -hT ${mp}"                    "$mdir/df.txt"
      [[ -s "$mdir/active_procs.txt" ]]  && html_section "aprocs-${safe_mp}"       "Active processes: ${mp}"         "$mdir/active_procs.txt"
      [[ -s "$mdir/mountstats_ops.txt" ]] && html_section "mstats-ops-${safe_mp}"  "Per-op latency: ${mp}"           "$mdir/mountstats_ops.txt"
      [[ -s "$mdir/nfsstat_m.txt" ]]     && html_section "nfsstat-m-${safe_mp}"    "nfsstat -m ${mp}"                "$mdir/nfsstat_m.txt"
      [[ -s "$mdir/mountstats.txt" ]]    && html_section "mstats-${safe_mp}"       "/proc/self/mountstats ${mp}"     "$mdir/mountstats.txt" "closed"
      echo "</div></div>"
    done
    echo "</section>"
  fi

  # ---- Per-Server Details ----
  if [[ $server_count -gt 0 ]]; then
    echo "<section id='per-server'><h2>Per-Server Details <a class='tiny' href='#top'>↑</a></h2>"
    echo "<div class='toc small'>"
    for i in $(seq 0 $((server_count - 1))); do
      safe_srv="${server_dirs[$i]}"
      echo "<a href='#server-${safe_srv}'>${server_labels[$i]}</a>"
    done
    echo "</div>"

    for i in $(seq 0 $((server_count - 1))); do
      safe_srv="${server_dirs[$i]}"
      sdir="$DATADIR/per_server/${safe_srv}"

      echo "<div class='card' id='server-${safe_srv}'>"
      echo "<h3>${server_labels[$i]} <a class='tiny' href='#per-server'>↑ servers</a></h3>"
      echo "<div class='grid cols-2'>"
      [[ -s "$sdir/server_info.txt" ]]       && html_section "sinfo-${safe_srv}"        "Server info &amp; egress NIC" "$sdir/server_info.txt"
      [[ -s "$sdir/nfs_connections.txt" ]]   && html_section "nfsconn-${safe_srv}"      "NFS TCP connections"          "$sdir/nfs_connections.txt"
      [[ -s "$sdir/ping.txt" ]]              && html_section "ping-${safe_srv}"         "ping latency"                 "$sdir/ping.txt"
      [[ -s "$sdir/route.txt" ]]             && html_section "route-${safe_srv}"        "ip route get"                 "$sdir/route.txt"
      [[ -s "$sdir/ip_link_dev.txt" ]]       && html_section "iplink-${safe_srv}"       "ip -s link (egress dev)"      "$sdir/ip_link_dev.txt"
      [[ -s "$sdir/ethtool.txt" ]]           && html_section "ethtool-${safe_srv}"      "ethtool (NIC settings)"       "$sdir/ethtool.txt"
      [[ -s "$sdir/ethtool_i.txt" ]]         && html_section "ethtool-i-${safe_srv}"    "ethtool -i (driver info)"     "$sdir/ethtool_i.txt"
      [[ -s "$sdir/ethtool_S.txt" ]]         && html_section "ethtool-S-${safe_srv}"    "ethtool -S (NIC stats)"       "$sdir/ethtool_S.txt" "closed"
      echo "</div></div>"
    done
    echo "</section>"
  fi

  echo "<hr class='sect-divider'/>"

  # ---- System Context ----
  echo "<section id='system-context'><h2>System Context <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  [[ -s "$DATADIR/system/uname.txt" ]]             && html_section 'uname'         'uname -a'                     "$DATADIR/system/uname.txt"
  [[ -s "$DATADIR/system/hostname.txt" ]]           && html_section 'hostname'      'hostname'                     "$DATADIR/system/hostname.txt"
  if [[ -s "$DATADIR/system/lsb_release.txt" ]]; then
    html_section 'lsb-release' 'lsb_release -a' "$DATADIR/system/lsb_release.txt"
  elif [[ -s "$DATADIR/system/os_release.txt" ]]; then
    html_section 'os-release' '/etc/os-release' "$DATADIR/system/os_release.txt"
  fi
  [[ -s "$DATADIR/system/packages.txt" ]]           && html_section 'packages'      'installed packages (nfs/sysstat)' "$DATADIR/system/packages.txt"
  [[ -s "$DATADIR/system/nfs_modules.txt" ]]        && html_section 'nfs-modules'   'loaded NFS kernel modules'     "$DATADIR/system/nfs_modules.txt"
  [[ -s "$DATADIR/system/sysctl_key_params.txt" ]]  && html_section 'sysctl-key'    'key sysctl parameters'         "$DATADIR/system/sysctl_key_params.txt"
  [[ -s "$DATADIR/system/sysctl_nfs.txt" ]]         && html_section 'sysctl-full'   'sysctl (nfs/sunrpc/net subset)' "$DATADIR/system/sysctl_nfs.txt" "closed"
  echo "</div></section>"

  echo "<p class='small'>Generated from diagnostics directory: <code>$(basename "$DATADIR")</code></p>"
  echo "</body></html>"
} > "$INDEX_HTML"

# If we extracted a tarball, move index.html next to the tarball and clean up
if [[ -n "$_EXTRACTED_DIR" ]]; then
  FINAL_HTML="$(dirname "$INPUT")/$(basename "$INPUT" .tar.gz).html"
  mv "$INDEX_HTML" "$FINAL_HTML"
  rm -rf "$_EXTRACTED_DIR"
  echo "$FINAL_HTML"
else
  echo "$INDEX_HTML"
fi
