#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# HOW TO ADD A NEW COMMAND / SECTION (quick checklist)
#
# A) Add a new SYSTEM-WIDE collector (single file output):
#    1) Go to:   ### [EP1] SYSTEM-WIDE COLLECTORS (safe + bounded)
#    2) Add a line using the run helper, e.g.:
#         run "mytool_status.txt"  mytool --flag1 --flag2
#       (it writes to $OUTDIR/mytool_status.txt safely with timeout/nice/ionice)
#    3) Go to:   ### [EP3] HTML — SYSTEM-WIDE SECTIONS
#       Add a new HTML block to render it:
#         echo "$(html_section 'mytool-status' 'mytool status' "$OUTDIR/mytool_status.txt")"
#    4) (Optional) Update the Table of Contents:
#         echo "<a href='#mytool-status'>mytool status</a>"
#
# B) Add a new PER-MOUNT collector (one file per mount):
#    1) Go to:   ### [EP2] PER-MOUNT COLLECTORS
#    2) Inside the for mp in ... loop, add:
#         run "mytool_${safe_mp}.txt"  mytool --target "$mp"
#    3) Go to:   ### [EP4] HTML — PER-MOUNT SUBSECTIONS
#       Inside each mount card, add a section line:
#         echo "$(html_section "mytool-${safe_mp}" "mytool ($mp)" "$OUTDIR/mytool_${safe_mp}.txt")"
#
# C) Add a NEW HTML SECTION GROUP (with its own anchor):
#    1) Go to:   ### [EP3] HTML — SYSTEM-WIDE SECTIONS
#    2) Copy an existing <section id='...'> ... </section> group and:
#         - change id="my-new-section-id"
#         - add a TOC link at ### [EP0] HTML — TABLE OF CONTENTS
#
# D) Naming & Safety:
#    - Always use the run helper to execute commands: run "<outfile>" <cmd ...>
#      It applies: timeout(10s), nice/ionice, error-safe capture.
#    - Never traverse the NFS directory tree (no 'find', no 'du' on the mount).
#    - Keep samples short (SAMPLE_SEC) to reduce load.
###############################################################################

# =================== Config ===================
OUTDIR="nfs_client_collect_$(date +%Y%m%d_%H%M%S)"
LOG_SINCE="${LOG_SINCE:-now-2h}"     # kernel log window
SAMPLE_SEC="${SAMPLE_SEC:-3}"    # seconds for short samplers
TIMEOUT_CMD="timeout 10s"
NICE="nice -n 19 ionice -c3"
PING_COUNT="${PING_COUNT:-10}"
PING_INT="${PING_INT:-0.2}"

mkdir -p "$OUTDIR"
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$OUTDIR/_collector.log"; }
run(){  # run <outfile> <cmd...> (bounded + nice)
  local outfile="$1"; shift
  { echo "## cmd: $*"; $NICE $TIMEOUT_CMD "$@" 2>&1 || true; } > "$OUTDIR/$outfile"
}

normalize_since() {
  local s="${1:-now-2h}"
  # Accept '2h', '30m', '1d', '7w', '45s' etc. → convert to 'now-2h' style
  if [[ "$s" =~ ^[0-9]+[smhdw]$ ]]; then
    echo "now-${s}"
    return
  fi
  # Pass through valid strings like 'now-2h', 'yesterday', '2025-09-18 12:00', '2 hours ago'
  echo "$s"
}

# HTML helpers (with anchors)
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
html_section() {  # html_section <id> <title> <filepath>
  local id="$1" title="$2" file="$3"
  cat <<HTML
<section id="${id}">
  <h2>${title} <a class="tiny" href="#top" title="Back to top">↑</a></h2>
  <details open><summary>show/hide</summary><pre>
$( if [[ -s "$file" ]]; then html_escape < "$file"; else echo "(empty or not available)"; fi )
  </pre></details>
</section>
HTML
}

# tiny CSS for anchors
NAV_CSS='
  body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; margin:24px; line-height:1.4;}
  h1{margin:0 0 8px;}
  h2{margin:20px 0 8px; font-size:1.1rem}
  .meta{color:#555; margin-bottom:16px}
  details{margin:6px 0 16px}
  summary{cursor:pointer; color:#0366d6}
  pre{background:#0b1020; color:#d5d7e2; padding:12px; border-radius:8px; overflow:auto; font-size:12px}
  code{background:#f6f8fa; padding:2px 4px; border-radius:4px}
  .grid{display:grid; gap:12px}
  .cols-2{grid-template-columns: repeat(auto-fit, minmax(320px,1fr));}
  .pill{display:inline-block; background:#eef6ff; color:#0353a4; padding:2px 8px; border-radius:999px; font-size:12px; margin-right:6px}
  .card{border:1px solid #e5e7eb; border-radius:10px; padding:12px}
  .small{font-size:12px; color:#666}
  a{color:#0366d6; text-decoration:none}
  a:hover{text-decoration:underline}
  .toc a{display:inline-block; margin:2px 8px 2px 0}
  .tiny{font-size:.8rem; margin-left:.25rem; text-decoration:none}
  .toc{border:1px solid #e5e7eb; border-radius:10px; padding:12px; margin:12px 0}
'

log "Auto-detecting NFS mounts and collecting lightweight diagnostics..."

# =================== Detect NFS mounts ===================
declare -A MOUNTS=()     # map: MOUNTPOINT -> SERVER_IP_OR_HOST
declare -A SRCPATHS=()   # map: MOUNTPOINT -> server:/export

if command -v nfsstat >/dev/null 2>&1; then
  # Parse "mountpoint from server:/export" header lines
  while IFS= read -r line; do
    mp=$(sed -n 's#^\(/[^ ]*\) from .*#\1#p' <<<"$line")
    srvp=$(sed -n 's#^.*/[^ ]* from \([^ ]*\).*#\1#p' <<<"$line")
    [[ -z "$mp" ]] && continue
    SRCPATHS["$mp"]="$srvp"
  done < <(nfsstat -m 2>/dev/null | sed -n '/ from /p' || true)

  # Try to extract addr= from subsequent lines per block
  if [[ ${#SRCPATHS[@]} -gt 0 ]]; then
    current=""
    while IFS= read -r line; do
      if grep -q " from " <<<"$line"; then
        current=$(sed -n 's#^\(/[^ ]*\) from .*#\1#p' <<<"$line")
      elif [[ -n "$current" ]]; then
        addr=$(sed -n 's#.*addr=\([^, ]*\).*#\1#p' <<<"$line" || true)
        if [[ -n "$addr" ]]; then
          MOUNTS["$current"]="$addr"
          current=""
        fi
      fi
    done < <(nfsstat -m 2>/dev/null || true)
  fi
fi

# Fallback: /proc/self/mountstats
if [[ ${#MOUNTS[@]} -eq 0 ]]; then
  while IFS= read -r line; do
    dev=$(awk '{print $2}' <<<"$line")        # server:/export
    mp=$(awk '{print $5}' <<<"$line")         # /mount/point
    [[ -z "$mp" || -z "$dev" ]] && continue
    host=${dev%%:*}
    MOUNTS["$mp"]="$host"
    SRCPATHS["$mp"]="$dev"
  done < <(grep -E '^device .* mounted on .* type nfs' /proc/self/mountstats 2>/dev/null || true)
fi

# Fallback: /proc/mounts
if [[ ${#MOUNTS[@]} -eq 0 ]]; then
  while read -r dev mp fstype opts _; do
    [[ "$fstype" =~ ^nfs ]] || continue
    host=${dev%%:*}
    MOUNTS["$mp"]="$host"
    SRCPATHS["$mp"]="$dev"
  done < /proc/mounts
fi

if [[ ${#MOUNTS[@]} -eq 0 ]]; then
  log "ERROR: No NFS mounts detected. Exiting."
  exit 1
fi

log "Detected ${#MOUNTS[@]} NFS mount(s):"
for mp in "${!MOUNTS[@]}"; do
  log " - $mp  (server=${MOUNTS[$mp]} source=${SRCPATHS[$mp]:-N/A})"
done

###############################################################################
### [EP1] SYSTEM-WIDE COLLECTORS (safe + bounded)
# Add new system-wide collectors here using:
#   run "<outfile>.txt"  <your_command> [args...]
# Then render it in HTML at [EP3].
###############################################################################
# Context
run "context_uname.txt"       uname -a
if command -v lsb_release >/dev/null 2>&1; then
  run "context_lsb_release.txt" lsb_release -a
else
  run "context_os_release.txt" bash -lc 'cat /etc/os-release || true'
fi
# Package listing (cross-platform)
if command -v dpkg >/dev/null 2>&1; then
  run "context_packages.txt"  bash -lc "dpkg -l | grep -E -i '(^ii.*(nfs|sysstat|nfs-common|nfs-utils))' || true"
elif command -v rpm >/dev/null 2>&1; then
  run "context_packages.txt"  bash -lc "rpm -qa | grep -E -i '(nfs|sysstat)' || true"
else
  run "context_packages.txt"  echo "No package manager detected (dpkg/rpm)"
fi
run "context_sysctl.txt"      bash -lc "sysctl -a 2>/dev/null | grep -E '^(net\.ipv4|sunrpc|fs\.nfs)' | head -n 500"

# NFS client stats / mounts
run "mounts.txt"              bash -lc "mount | grep -E ' type nfs| type nfs4' || true"
run "proc_mounts.txt"         bash -lc "cat /proc/mounts | grep -E ' nfs | nfs4 ' || true"
run "nfsstat_m.txt"           nfsstat -m || true
run "nfsstat_client.txt"      nfsstat -c || true
run "nfsstat_rpc.txt"         nfsstat -r || true
run "nfsstat_net.txt"         nfsstat -n || true
run "proc_net_rpc_nfs.txt"    bash -lc "cat /proc/net/rpc/nfs || true"

# Quick samplers (short + bounded)
if command -v nfsiostat >/dev/null 2>&1; then
  run "nfsiostat.txt"         nfsiostat 1 "$SAMPLE_SEC"
fi
if command -v mountstats >/dev/null 2>&1; then
  run "mountstats_summary.txt" mountstats -S
fi

# Logs (bounded)
if command -v journalctl >/dev/null 2>&1; then
  SINCE_ARG="$(normalize_since "$LOG_SINCE")"
  # Try the parsed --since; if it fails, fall back to last 2000 lines
  if journalctl -k --since "$SINCE_ARG" --no-pager >/dev/null 2>&1; then
    run "kernel_journal_tail.txt" bash -lc "journalctl -k --since '$SINCE_ARG' --no-pager | tail -n 2000"
  else
    run "kernel_journal_tail.txt" bash -lc "journalctl -k -n 2000 --no-pager"
  fi
else
  run "dmesg_tail.txt"        dmesg | tail -n 2000
fi

# System load
if command -v iostat >/dev/null 2>&1; then
  run "iostat_x.txt"          iostat -x 1 "$SAMPLE_SEC"
fi
if command -v mpstat >/dev/null 2>&1; then
  run "mpstat.txt"            mpstat 1 "$SAMPLE_SEC"
fi
run "vmstat.txt"              vmstat 1 "$SAMPLE_SEC"
run "mem_free.txt"            free -h
run "uptime.txt"              uptime

# Network basics
run "ss_tni.txt"              ss -tni
if command -v netstat >/dev/null 2>&1; then
  run "netstat_s.txt"         netstat -s
else
  run "ss_summary.txt"        ss -s
fi
run "ip_link_stats.txt"       ip -s link

###############################################################################
### [EP2] PER-MOUNT COLLECTORS
# Add per-mount collectors INSIDE this loop (one output per mount using $safe_mp).
###############################################################################
for mp in "${!MOUNTS[@]}"; do
  safe_mp="${mp//\//_}"
  # Mountstats slice and df are examples of per-mount outputs:
  run "mountstats_${safe_mp}.txt" bash -lc \
    "awk 'BEGIN{p=0} /^device .* mounted on /{if(p) exit} /mounted on ${mp//\//\\/}/{p=1} p{print}' /proc/self/mountstats"
  run "df_${safe_mp}.txt"      df -hT "$mp"
done

# Reachability & NIC stats per server (derived from routing to the server IP)
for mp in "${!MOUNTS[@]}"; do
  server="${MOUNTS[$mp]}"
  [[ -z "$server" ]] && continue
  safe_srv="$(sed 's#[^A-Za-z0-9._-]#_#g' <<<"$server")"

  # Resolve hostname to IPv4 if needed
  ipaddr="$server"
  if ! [[ "$server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ipaddr=$(getent ahostsv4 "$server" 2>/dev/null | awk 'NR==1{print $1}')
  fi

  if [[ -n "$ipaddr" ]]; then
    run "route_to_${safe_srv}.txt" bash -lc "ip route get $ipaddr"
    # FIXED awk quoting (no backslashes)
    dev=$(ip route get "$ipaddr" 2>/dev/null | awk '/ dev /{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    if [[ -n "$dev" && -x "$(command -v ethtool)" ]]; then
      run "ethtool_S_${dev}.txt" ethtool -S "$dev"
    fi
    run "ping_${safe_srv}.txt"   ping -c "$PING_COUNT" -i "$PING_INT" "$ipaddr"
  fi
done

# =================== QUICKLOOK ===================
{
  echo "== Detected NFS Mounts =="
  for mp in "${!MOUNTS[@]}"; do
    printf "%-30s -> %s (%s)\n" "$mp" "${MOUNTS[$mp]}" "${SRCPATHS[$mp]:-N/A}"
  done
  echo
  echo "== nfsstat -c (top) =="
  head -n 50 "$OUTDIR/nfsstat_client.txt" 2>/dev/null || true
  echo
  echo "== nfsiostat sample =="
  head -n 80 "$OUTDIR/nfsiostat.txt" 2>/dev/null || echo "nfsiostat not available"
  echo
  echo "== iostat -x sample =="
  head -n 80 "$OUTDIR/iostat_x.txt" 2>/dev/null || echo "iostat not available"
  echo
  echo "== TCP summary =="
  (head -n 120 "$OUTDIR/netstat_s.txt" 2>/dev/null) || (head -n 120 "$OUTDIR/ss_summary.txt" 2>/dev/null) || true
} > "$OUTDIR/QUICKLOOK.txt"

# =================== HTML report (with anchors/TOC) ===================
INDEX_HTML="$OUTDIR/index.html"
{
  echo "<!doctype html><html><head><meta charset='utf-8'/>"
  echo "<title>NFS Client Diagnostics Report</title>"
  echo "<style>${NAV_CSS}</style>"
  echo "</head><body>"
  echo "<a id='top'></a>"
  echo "<h1>NFS Client Diagnostics Report</h1>"
  echo "<div class='meta'>Generated: $(date '+%F %T') &nbsp; • &nbsp; Host: $(hostname)</div>"

  # ===== [EP0] HTML — TABLE OF CONTENTS =====
  echo "<div class='toc'><b>Table of Contents</b><br/>"
  echo "<a href='#detected-mounts'>Detected NFS Mounts</a>"
  echo "<a href='#quick-look'>Quick Look</a>"
  echo "<a href='#client-stats'>NFS Client Stats</a>"
  echo "<a href='#kernel-logs'>Kernel Logs</a>"
  echo "<a href='#system-load'>System Load</a>"
  echo "<a href='#network'>Network</a>"
  echo "<a href='#per-mount'>Per-Mount Details</a>"
  echo "<a href='#system-context'>System Context</a>"
  # To add your new section here:
  # echo "<a href='#my-new-section'>My New Section</a>"
  echo "</div>"

  # ===== Detected mounts =====
  echo "<section id='detected-mounts' class='card'>"
  echo "<h2>Detected NFS Mounts <a class='tiny' href='#top'>↑</a></h2><ul>"
  for mp in "${!MOUNTS[@]}"; do
    srv="${MOUNTS[$mp]}"; src="${SRCPATHS[$mp]:-N/A}"
    safe_mp="${mp//\//_}"
    echo "<li><span class='pill'>mount</span> <b><a href='#mount-${safe_mp}'>${mp}</a></b> &nbsp; <span class='small'>(server: ${srv}, source: ${src})</span></li>"
  done
  echo "</ul></section>"

  # ===== Quick look =====
  echo "<section id='quick-look' class='card'>"
  echo "<h2>Quick Look <a class='tiny' href='#top'>↑</a></h2><pre>"
  html_escape < "$OUTDIR/QUICKLOOK.txt"
  echo "</pre></section>"

  #############################################################################
  ### [EP3] HTML — SYSTEM-WIDE SECTIONS
  # Add new system-wide sections here using:
  #   echo "$(html_section 'your-anchor-id' 'Your Title' "$OUTDIR/your_output.txt")"
  # Also remember to add the TOC link in [EP0].
  #############################################################################
  echo "<section id='client-stats'><h2>NFS Client Stats <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  echo "$(html_section 'nfsstat-m' 'nfsstat -m' "$OUTDIR/nfsstat_m.txt")"
  echo "$(html_section 'nfsstat-c' 'nfsstat -c (client)' "$OUTDIR/nfsstat_client.txt")"
  echo "$(html_section 'nfsstat-r' 'nfsstat -r (RPC)' "$OUTDIR/nfsstat_rpc.txt")"
  echo "$(html_section 'nfsstat-n' 'nfsstat -n (network)' "$OUTDIR/nfsstat_net.txt")"
  echo "$(html_section 'proc-rpc-nfs' '/proc/net/rpc/nfs' "$OUTDIR/proc_net_rpc_nfs.txt")"
  echo "$(html_section 'mounts' 'mount | grep nfs' "$OUTDIR/mounts.txt")"
  echo "$(html_section 'proc-mounts' '/proc/mounts (nfs entries)' "$OUTDIR/proc_mounts.txt")"
  echo "</div></section>"

  echo "$(html_section 'kernel-logs' 'Kernel logs (tail window)' "$OUTDIR/kernel_journal_tail.txt")"

  echo "<section id='system-load'><h2>System Load <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  echo "$(html_section 'iostat-x' 'iostat -x sample' "$OUTDIR/iostat_x.txt")"
  echo "$(html_section 'nfsiostat' 'nfsiostat sample' "$OUTDIR/nfsiostat.txt")"
  echo "$(html_section 'mpstat' 'mpstat sample' "$OUTDIR/mpstat.txt")"
  echo "$(html_section 'vmstat' 'vmstat sample' "$OUTDIR/vmstat.txt")"
  echo "</div></section>"

  echo "<section id='network'><h2>Network <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  echo "$(html_section 'tcp-summary' 'TCP summary (netstat -s / ss -s)' "$OUTDIR/netstat_s.txt")"
  echo "$(html_section 'ip-link' 'ip -s link' "$OUTDIR/ip_link_stats.txt")"
  echo "</div></section>"

  # ===== Per-mount details =====
  echo "<section id='per-mount'><h2>Per-Mount Details <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='toc small'>"
  for mp in "${!MOUNTS[@]}"; do
    safe_mp="${mp//\//_}"
    echo "<a href='#mount-${safe_mp}'>${mp}</a>"
  done
  echo "</div>"

  #############################################################################
  ### [EP4] HTML — PER-MOUNT SUBSECTIONS
  # Inside each mount card, add sub-sections for any per-mount outputs
  # you created in [EP2], e.g.:
  #   echo "$(html_section "mytool-${safe_mp}" "mytool ($mp)" "$OUTDIR/mytool_${safe_mp}.txt")"
  #############################################################################
  for mp in "${!MOUNTS[@]}"; do
    safe_mp="${mp//\//_}"
    srv="${MOUNTS[$mp]}"; safe_srv="$(sed 's#[^A-Za-z0-9._-]#_#g' <<<"$srv")"
    echo "<div class='card' id='mount-${safe_mp}'>"
    echo "<h3>${mp} <a class='tiny' href='#per-mount'>↑</a></h3>"
    echo "$(html_section "df-${safe_mp}" "df -hT ${mp}" "$OUTDIR/df_${safe_mp}.txt")"
    echo "$(html_section "mountstats-${safe_mp}" "/proc/self/mountstats (${mp})" "$OUTDIR/mountstats_${safe_mp}.txt")"
    [[ -s "$OUTDIR/route_to_${safe_srv}.txt" ]] && echo "$(html_section "route-${safe_srv}" "ip route get ${srv}" "$OUTDIR/route_to_${safe_srv}.txt")"
    for f in "$OUTDIR"/ethtool_S_*.txt; do [[ -e "$f" ]] && echo "$(html_section "$(basename "$f")" "$(basename "$f")" "$f")"; done
    [[ -s "$OUTDIR/ping_${safe_srv}.txt" ]] && echo "$(html_section "ping-${safe_srv}" "ping ${srv}" "$OUTDIR/ping_${safe_srv}.txt")"
    # Example: render your per-mount tool output here
    # echo "$(html_section "mytool-${safe_mp}" "mytool ($mp)" "$OUTDIR/mytool_${safe_mp}.txt")"
    echo "</div>"
  done
  echo "</section>"

  # ===== System context =====
  echo "<section id='system-context'><h2>System Context <a class='tiny' href='#top'>↑</a></h2>"
  echo "<div class='grid cols-2'>"
  echo "$(html_section 'uname' 'uname -a' "$OUTDIR/context_uname.txt")"
  if [[ -s "$OUTDIR/context_lsb_release.txt" ]]; then
    echo "$(html_section 'lsb-release' 'lsb_release -a' "$OUTDIR/context_lsb_release.txt")"
  else
    echo "$(html_section 'os-release' '/etc/os-release' "$OUTDIR/context_os_release.txt")"
  fi
  echo "$(html_section 'packages' 'dpkg -l (nfs/sysstat)' "$OUTDIR/context_packages.txt")"
  echo "$(html_section 'sysctl' 'sysctl (nfs/sunrpc/tcp subset)' "$OUTDIR/context_sysctl.txt")"
  echo "</div></section>"

  echo "<p class='small'>All raw artifacts were bundled. To view them, extract the tarball:<br><code>tar -xzf ${OUTDIR}.tar.gz</code></p>"
  echo "</body></html>"
} > "$INDEX_HTML"

# =================== Bundle & Clean ===================
TARFILE="${OUTDIR}.tar.gz"
log "Bundling artifacts into: $TARFILE"
tar -czf "$TARFILE" "$OUTDIR"

# Verify tarball before cleanup
if tar -tzf "$TARFILE" >/dev/null 2>&1; then
  rm -rf "$OUTDIR"
  log "Cleanup complete. Remaining artifact: $TARFILE"
else
  log "WARNING: Tar verification failed. Leaving $OUTDIR for inspection."
fi

