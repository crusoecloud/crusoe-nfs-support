#!/bin/bash
# nfs_audit.sh

HOSTS_FILE="hosts.txt"
OUTPUT_FILE="nfs_mounts.txt"
SSH_PORT=22
NFS_TEST_TIMEOUT=5  # Timeout in seconds for read/write tests

# Header
printf "%-30s %-6s %-6s %-6s %s\n" "HOST" "COUNT" "READ" "WRITE" "MOUNT_POINTS" > "$OUTPUT_FILE"
printf "%-30s %-6s %-6s %-6s %s\n" "----" "-----" "----" "-----" "------------" >> "$OUTPUT_FILE"

while read -r host || [[ -n "$host" ]]; do
    [[ -z "$host" || "$host" =~ ^# ]] && continue

    # Extract IP/hostname from user@host format for connectivity checks
    ip="${host#*@}"

    # Pre-flight connectivity check before attempting SSH
    if command -v nc &>/dev/null; then
        if ! nc -z -w 3 "$ip" "$SSH_PORT" 2>/dev/null; then
            printf "%-30s %-6s %-6s %-6s %s\n" "$host" "ERROR" "-" "-" "host unreachable (port $SSH_PORT closed)" >> "$OUTPUT_FILE"
            continue
        fi
    elif command -v fping &>/dev/null; then
        if ! fping -q -c 1 -t 3000 "$ip" 2>/dev/null; then
            printf "%-30s %-6s %-6s %-6s %s\n" "$host" "ERROR" "-" "-" "host unreachable (no ping response)" >> "$OUTPUT_FILE"
            continue
        fi
    fi
    # If neither nc nor fping available, fall through to SSH (which has its own timeout)

    result=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "NFS_TEST_TIMEOUT=$NFS_TEST_TIMEOUT"'
        mounts=$(findmnt -t nfs -n -o TARGET 2>/dev/null)
        if [ -z "$mounts" ]; then
            echo "0|0|0|none"
            exit 0
        fi

        count=0
        read_ok=0
        write_ok=0
        mount_status=""

        while IFS= read -r mount; do
            [ -z "$mount" ] && continue
            count=$((count + 1))

            # Read test: try to list the directory (with timeout for hung NFS)
            if timeout "$NFS_TEST_TIMEOUT" ls "$mount" >/dev/null 2>&1; then
                r="R"
                read_ok=$((read_ok + 1))
            else
                r="-"
            fi

            # Write test: try to create and remove a temp file (with timeout for hung NFS)
            testfile="$mount/.tmp_crusoe_nfs_audit_test_$$"
            if timeout "$NFS_TEST_TIMEOUT" touch "$testfile" 2>/dev/null && timeout "$NFS_TEST_TIMEOUT" rm -f "$testfile" 2>/dev/null; then
                w="W"
                write_ok=$((write_ok + 1))
            else
                timeout "$NFS_TEST_TIMEOUT" rm -f "$testfile" 2>/dev/null
                w="-"
            fi

            mount_status="${mount_status}${mount}(${r}${w}),"
        done <<< "$mounts"

        mount_status=${mount_status%,}
        echo "${count}|${read_ok}|${write_ok}|${mount_status}"
    ' 2>/dev/null)

    if [ -n "$result" ]; then
        count=$(echo "$result" | cut -d'|' -f1)
        read_ok=$(echo "$result" | cut -d'|' -f2)
        write_ok=$(echo "$result" | cut -d'|' -f3)
        mounts=$(echo "$result" | cut -d'|' -f4)
        printf "%-30s %-6s %-6s %-6s %s\n" "$host" "$count" "$read_ok" "$write_ok" "$mounts" >> "$OUTPUT_FILE"
    else
        printf "%-30s %-6s %-6s %-6s %s\n" "$host" "ERROR" "-" "-" "connection failed" >> "$OUTPUT_FILE"
    fi
done < "$HOSTS_FILE"

cat "$OUTPUT_FILE"

# Example output (nfs_mounts.txt):
# HOST                           COUNT  READ   WRITE  MOUNT_POINTS
# ----                           -----  ----   -----  ------------
# 192.168.1.10                   3      3      2      /mnt/nfs1(RW),/mnt/nfs2(RW),/mnt/data(R-)
# 192.168.1.11                   1      1      1      /mnt/shared(RW)
# 192.168.1.12                   0      0      0      none
# 192.168.1.13                   ERROR  -      -      host unreachable (port 22 closed)
# 192.168.1.14                   ERROR  -      -      connection failed
# 192.168.1.15                   2      1      0      /mnt/nfs1(RW),/mnt/hung(--) # hung mount timed out
#
# Legend: R=read OK, W=write OK, -=failed or timed out
# READ/WRITE columns show count of mounts that passed each test
# NFS_TEST_TIMEOUT controls how long to wait for hung mounts (default: 5s)
