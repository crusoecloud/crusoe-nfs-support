# crusoe-nfs-support

This repository hosts scripts by the Crusoe Cloud team to assist with the Shared Disk NFS migration process.

## How to install NFS drivers for Crusoe Shared Disks

To apply this script to multiple VMs at once, it is recommended to use the `pssh` and `pscp` helper programs:

> [!IMPORTANT]
> Installing the Crusoe NFS drivers can disrupt existing NFS mounts on your VM. If applicable, please stop any active workflows before proceeding.

1. Locally, download the `crusoe_shared_disks_nfs_setup.py` script to a file:

```
wget -O crusoe_shared_disks_nfs_setup.py https://github.com/crusoecloud/crusoe-nfs-support/raw/refs/heads/main/crusoe_shared_disks_nfs_setup.py
```

2. Create a file, named hosts.txt, that includes the IP addresses, line-by-line, of the VMs to apply this script to. For example, it may look something like this:

```
touch hosts.txt
echo "ubuntu@1.2.3.4" >> hosts.txt
echo "ubuntu@1.2.3.5" >> hosts.txt
```

3. Use pscp and pssh to apply the script to multiple files at once. Note that the setup script can take a long time (more than a few minutes).

```
pscp -h hosts.txt crusoe_shared_disks_nfs_setup.py /home/ubuntu/crusoe_shared_disks_nfs_setup.py
pssh -t 0 -h hosts.txt "export DEBIAN_FRONTEND=noninteractive && python3 /home/ubuntu/crusoe_shared_disks_nfs_setup.py -y"
```

## How to remount Virtiofs to NFS for Crusoe Shared Disks

**You should only use the remount script when you are not actively using any of your existing shared volume mounts.**

To apply this script to multiple VMs at once, it is recommended to use the `pssh` and `pscp` helper programs:

> [!IMPORTANT]
> The remount script WILL interrupt existing Virtiofs mounts on your VM. Please stop any active workflows before proceeding.

1. Locally, download the `crusoe_shared_disks_virtiofs_to_nfs.py` script to a file:

```
wget -O crusoe_shared_disks_virtiofs_to_nfs.py https://github.com/crusoecloud/crusoe-nfs-support/raw/refs/heads/main/crusoe_shared_disks_virtiofs_to_nfs.py
```

2. Obtain the list of disk names to disk IDs for your project. You will need your project's ID and the Crusoe CLI to run this command. If you are having troubles running this command, reach out to Crusoe support. The command is as follows:

```
crusoe storage disks list --project-id <PROJECT_ID> --format json | jq -r '[.[] | select(.type == "shared-volume")] | map("\(.name),\(.id)") | join("+")'
```

The output should look similar to this: `disk-name-1,00000000-0000-0000-0000-000000000000+disk-name-2,00000000-0000-0000-0000-000000000000`

Copy this to the `<PASTE_DISK_TEXT_HERE>` section of the command in step (4).

3. Create a file, named hosts.txt, that includes the IP addresses, line-by-line, of the VMs to apply this script to. For example, it may look something like this:

```
touch hosts.txt
echo "ubuntu@1.2.3.4" >> hosts.txt
echo "ubuntu@1.2.3.5" >> hosts.txt
```

4. Use pscp and pssh to apply the script to multiple files at once. Please replace `<PASTE_DISK_TEXT_HERE>` with the data found in step (2). Note that the setup script can take a long time (more than a few minutes).

```
pscp -h hosts.txt crusoe_shared_disks_virtiofs_to_nfs.py /home/ubuntu/crusoe_shared_disks_virtiofs_to_nfs.py
pssh -t 0 -h hosts.txt "export DEBIAN_FRONTEND=noninteractive && python3 /home/ubuntu/crusoe_shared_disks_virtiofs_to_nfs.py -y --name-ids <PASTE_DISK_TEXT_HERE>"
```

## NFS Client Support Bundle (Diagnostics Collection)

The `nfs_client_support_bundle.sh` script collects comprehensive diagnostics from NFS clients to help troubleshoot performance issues, connectivity problems, or mount failures.

### Features

- **Auto-detects NFS mounts** using multiple fallback methods
- **Lightweight & safe**: No filesystem traversal, bounded sampling, nice/ionice priority
- **Comprehensive data collection**:
  - NFS client statistics (nfsstat, nfsiostat, mountstats)
  - System load metrics (iostat, mpstat, vmstat)
  - Network diagnostics (ping, routing, TCP stats, ethtool)
  - Kernel logs (journalctl/dmesg)
  - Per-mount details (df, mountstats, reachability)
- **Interactive HTML report** with collapsible sections and table of contents
- **Quick-look summary** for rapid triage

### Usage

1. Locally, download the `nfs_client_support_bundle.sh` script to a file:

```bash
wget -O nfs_client_support_bundle.sh https://github.com/crusoecloud/crusoe-nfs-support/raw/refs/heads/main/nfs_client_support_bundle.sh
chmod +x nfs_client_support_bundle.sh
```

2. Run the script (no root required for most data):

```bash
./nfs_client_support_bundle.sh
```

3. Customize collection via environment variables:

```bash
# Collect last 1 hour of kernel logs, sample for 5 seconds
LOG_SINCE=1h SAMPLE_SEC=5 ./nfs_client_support_bundle.sh

# Longer ping tests
PING_COUNT=50 PING_INT=0.1 ./nfs_client_support_bundle.sh
```

### Output

The script creates a timestamped tarball: `nfs_client_collect_YYYYMMDD_HHMMSS.tar.gz`

**Contents:**
- `index.html` - Interactive HTML report (open in browser)
- `QUICKLOOK.txt` - Quick summary for rapid triage
- Raw diagnostic files (nfsstat, iostat, logs, etc.)

**To view the report:**

```bash
# Extract the tarball
tar -xzf nfs_client_collect_*.tar.gz

# Open the HTML report in a browser
cd nfs_client_collect_*/
open index.html  # macOS
xdg-open index.html  # Linux
```

### Configuration Options

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `LOG_SINCE` | `now-2h` | Kernel log time window (e.g., `1h`, `30m`, `yesterday`) |
| `SAMPLE_SEC` | `3` | Sampling duration for iostat/mpstat/vmstat |
| `PING_COUNT` | `10` | Number of ping packets to each NFS server |
| `PING_INT` | `0.2` | Interval between ping packets (seconds) |

### Requirements

**Required:**
- `bash` 4.0+
- `nfsstat` (from `nfs-common` or `nfs-utils` package)

**Optional (but recommended):**
- `nfsiostat` (from `nfs-common` or `nfs-utils`)
- `iostat`, `mpstat` (from `sysstat` package)
- `ethtool` (for NIC statistics)
- `journalctl` (for kernel logs, otherwise uses `dmesg`)

### When to Use

Run this script when experiencing:
- **Slow NFS performance** (high latency, low throughput)
- **NFS mount hangs or timeouts**
- **Application stalls** when accessing NFS mounts
- **Network connectivity issues** to NFS servers
- **High CPU/IO wait** on NFS operations

### Safety Notes

- **Non-intrusive**: Uses `nice`/`ionice` to minimize system impact
- **Bounded**: All samplers have 10-second timeout limits
- **No filesystem traversal**: Does not run `find` or `du` on NFS mounts
- **Read-only**: Only collects data, does not modify system state
