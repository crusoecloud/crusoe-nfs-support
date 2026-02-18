"""
This script migrates NFS mounts from IP-based to DNS-based (nfs.crusoecloudcompute.com).
It operates on multiple VMs via SSH using the VM list in ./crusoe/icat-vms.json.

Usage:
    python crusoe_shared_disks_migrate.py help
        - Show this help message

    python crusoe_shared_disks_migrate.py list-vms <project_id> [-y]
        - Lists VMs in eu-iceland1-a location with their public IPs
        - Saves VM list to ./crusoe/icat-vms.json for review
        - Run this FIRST to generate the VM list

    python crusoe_shared_disks_migrate.py unmount [-y]
        - Connects to each VM in icat-vms.json via SSH
        - Records current NFS mounts on each VM to ./crusoe/mounts.json
        - Unmounts all NFS mounts on all VMs

    python crusoe_shared_disks_migrate.py remount [-y]
        - Remounts volumes recorded by 'unmount' using DNS on all VMs

    python crusoe_shared_disks_migrate.py fstab [-y]
        - Updates /etc/fstab to use DNS instead of IP-based mounts on all VMs

    python crusoe_shared_disks_migrate.py rollback [-y]
        - Rolls back to IP-based mounts using saved mount info on all VMs

    python crusoe_shared_disks_migrate.py verify-mounts
        - Verifies NFS mounts on all VMs in icat-vms.json
        - Tests read and write access to each mount point
        - Outputs results to nfs_mounts.txt

NFS Mount Options:
    IP-based mount (old):
        mount -t nfs <IP>:/volumes/<volume_id> /mount/point

    DNS-based mount (new):
        mount -o vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=30 \\
            nfs.crusoecloudcompute.com:/volumes/<volume_id> /mount/point

    Key differences:
        - DNS-based mounts use nfs.crusoecloudcompute.com instead of a specific IP
        - remoteports=dns enables DNS-based endpoint resolution for better load balancing
        - _netdev tells the system to delay the mount attempt until the network is fully up
        - x-systemd.automount and x-systemd.idle-timeout=30 enable automatic mount/unmount via systemd
        - nofail prevents the VM from dropping into emergency mode if the mount fails

    Example fstab entry (DNS-based):
        nfs.crusoecloudcompute.com:/volumes/<volume_id> /mount/point nfs vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=30 0 0

If you have any questions, don't hesitate to reach out to Crusoe support.
"""

import argparse
import base64
import shlex
import subprocess
import sys
import json
import os

# START statics
CRUSOE_NFS_DOMAIN = "nfs.crusoecloudcompute.com"
CRUSOE_DIR = "./crusoe"
MOUNTS_FILE = os.path.join(CRUSOE_DIR, "mounts.json")
ICAT_VMS_FILE = os.path.join(CRUSOE_DIR, "icat-vms.json")
VERIFY_OUTPUT_FILE = "nfs_mounts.txt"
TARGET_LOCATION = "eu-iceland1-a"
NFS_TEST_TIMEOUT = 5  # Timeout in seconds for read/write tests
# END statics


def run_command(command, timeout=5):
    """Execute a shell command and return (stdout, error)."""
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
            shell=True,
            timeout=timeout
        )
        return result.stdout.strip(), None
    except subprocess.TimeoutExpired as e:
        return None, f"Command timed out: {e}"
    except subprocess.CalledProcessError as e:
        return None, f"Command failed (exit {e.returncode}): {e.stderr.strip()}"
    except Exception as e:
        return None, str(e)


def get_current_mounts():
    """Get current NFS mounts. Returns list of mount info dicts or None on error."""
    out, err = run_command("findmnt -t nfs --json")
    if err:
        # Check if it's just "no mounts found" vs actual error
        if "no mounts found" in str(err).lower() or out == "":
            return []
        print(f"Error getting current mounts: {err}")
        return None

    if not out:
        return []

    try:
        mounts_json = json.loads(out)
    except json.JSONDecodeError as e:
        print(f"Error parsing mount info: {e}")
        return None

    mounts = []
    for target in mounts_json.get("filesystems", []):
        source = target.get("source", "")
        mount_point = target.get("target", "")
        options = target.get("options", "")

        if ":/volumes/" not in source:
            print(f"Warning: Skipping non-Crusoe NFS mount: {source}")
            continue

        # Extract IP and volume ID from source (format: IP:/volumes/VOLUME_ID)
        parts = source.split(":/volumes/")
        ip_address = parts[0]
        volume_id = parts[1]

        mounts.append({
            "mount_point": mount_point,
            "volume_id": volume_id,
            "ip_address": ip_address,
            "options": options
        })

    return mounts


def verify_dns_reachable():
    """Check if the NFS domain is reachable."""
    _, err = run_command(f"ping -c 1 {CRUSOE_NFS_DOMAIN}")
    return err is None


def ensure_crusoe_dir():
    """Create ./crusoe directory if it doesn't exist."""
    if not os.path.exists(CRUSOE_DIR):
        os.makedirs(CRUSOE_DIR)
        print(f"Created directory: {CRUSOE_DIR}")
    else:
        print(f"Directory already exists: {CRUSOE_DIR}")


def save_mounts(mounts):
    """Save mount information to the crusoe directory."""
    with open(MOUNTS_FILE, "w") as f:
        json.dump(mounts, f, indent=2)
    print(f"Saved {len(mounts)} mount(s) to {MOUNTS_FILE}")


def load_mounts():
    """Load mount information from the crusoe directory."""
    if not os.path.exists(MOUNTS_FILE):
        print(f"Error: No saved mounts found at {MOUNTS_FILE}")
        print("Please run 'unmount' first to record existing mounts.")
        return None

    with open(MOUNTS_FILE, "r") as f:
        mounts = json.load(f)

    print(f"Loaded {len(mounts)} mount(s) from {MOUNTS_FILE}")
    return mounts


def load_vms():
    """Load VM list from the icat-vms.json file."""
    if not os.path.exists(ICAT_VMS_FILE):
        print(f"Error: No VM list found at {ICAT_VMS_FILE}")
        print("Please run 'list-vms <project_id>' first to generate the VM list.")
        return None

    with open(ICAT_VMS_FILE, "r") as f:
        vms = json.load(f)

    # Filter to only VMs with public IPs
    vms_with_ips = [vm for vm in vms if vm.get("public_ip")]
    vms_without_ips = [vm for vm in vms if not vm.get("public_ip")]

    if vms_without_ips:
        print(f"Warning: {len(vms_without_ips)} VM(s) have no public IP and will be skipped:")
        for vm in vms_without_ips:
            print(f"  - {vm.get('name', 'unknown')}")

    print(f"Loaded {len(vms_with_ips)} VM(s) with public IPs from {ICAT_VMS_FILE}")
    return vms_with_ips


def run_remote_command(host, command, timeout=30):
    """Execute a command on a remote host via SSH."""
    # Prepend ubuntu@ if no user specified
    if "@" not in host:
        host = f"ubuntu@{host}"
    ssh_cmd = f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 {host} {shlex.quote(command)}"
    return run_command(ssh_cmd, timeout=timeout)


def get_remote_mounts(host):
    """Get current NFS mounts from a remote host. Returns list of mount info dicts or None on error."""
    out, err = run_remote_command(host, "findmnt -t nfs --json")
    if err:
        # Check if it's just "no mounts found" vs actual error
        if "no mounts found" in str(err).lower() or out == "":
            return []
        print(f"  Error getting mounts: {err}")
        return None

    if not out:
        return []

    try:
        mounts_json = json.loads(out)
    except json.JSONDecodeError as e:
        print(f"  Error parsing mount info: {e}")
        return None

    mounts = []
    for target in mounts_json.get("filesystems", []):
        source = target.get("source", "")
        mount_point = target.get("target", "")
        options = target.get("options", "")

        if ":/volumes/" not in source:
            print(f"  Warning: Skipping non-Crusoe NFS mount: {source}")
            continue

        # Extract IP and volume ID from source (format: IP:/volumes/VOLUME_ID)
        parts = source.split(":/volumes/")
        ip_address = parts[0]
        volume_id = parts[1]

        mounts.append({
            "mount_point": mount_point,
            "volume_id": volume_id,
            "ip_address": ip_address,
            "options": options
        })

    return mounts


def do_unmount(auto_confirm):
    """Unmount mode: create dir, record mounts, unmount all NFS on all VMs."""
    # Step a: Create ./crusoe directory
    ensure_crusoe_dir()

    # Step b: Load VMs from icat-vms.json
    vms = load_vms()
    if vms is None:
        return False

    if len(vms) == 0:
        print("No VMs to process.")
        return True

    # Step c: Collect mounts from all VMs
    all_vm_mounts = {}
    total_mounts = 0

    print("\n" + "-" * 70)
    print("Collecting NFS mounts from all VMs...")
    print("-" * 70)

    for vm in vms:
        vm_name = vm["name"]
        vm_ip = vm["public_ip"]
        print(f"\n[{vm_name}] ({vm_ip})")

        mounts = get_remote_mounts(vm_ip)
        if mounts is None:
            print(f"  Failed to get mounts, skipping this VM")
            continue

        if len(mounts) == 0:
            print(f"  No NFS mounts found")
        else:
            print(f"  Found {len(mounts)} NFS mount(s):")
            for mount in mounts:
                print(f"    - {mount['volume_id']} at {mount['mount_point']}")

        all_vm_mounts[vm_name] = {
            "ip": vm_ip,
            "mounts": mounts
        }
        total_mounts += len(mounts)

    # Count VMs that actually have mounts (for user-facing messages)
    vms_with_mounts = sum(1 for vm_data in all_vm_mounts.values() if len(vm_data.get("mounts", [])) > 0)

    print("\n" + "-" * 70)
    print(f"Total: {total_mounts} NFS mount(s) across {vms_with_mounts} VM(s)")
    print("-" * 70)

    if total_mounts == 0:
        # Don't overwrite existing mounts file if no mounts are currently found
        if os.path.exists(MOUNTS_FILE):
            print("No NFS mounts found. Existing mounts file preserved.")
            print(f"(If you want to clear the saved mounts, delete {MOUNTS_FILE})")
        else:
            print("No NFS mounts found to unmount.")
            with open(MOUNTS_FILE, "w") as f:
                json.dump(all_vm_mounts, f, indent=2)
        return True

    if not auto_confirm:
        response = input(f"This will unmount {total_mounts} NFS mount(s) across {vms_with_mounts} VM(s). Continue? (y/N) ")
        if response.lower() != "y":
            print("Operation canceled.")
            return False

    # Save mounts before unmounting
    with open(MOUNTS_FILE, "w") as f:
        json.dump(all_vm_mounts, f, indent=2)
    print(f"Saved mount information to {MOUNTS_FILE}")

    # Step d: Unmount all NFS mounts on all VMs
    total_failed = 0
    total_succeeded = 0

    for vm_name, vm_data in all_vm_mounts.items():
        vm_ip = vm_data["ip"]
        mounts = vm_data["mounts"]

        if len(mounts) == 0:
            continue

        print(f"\n[{vm_name}] ({vm_ip}) - Unmounting {len(mounts)} volume(s)...")

        for mount in mounts:
            mount_point = mount["mount_point"]
            print(f"  Unmounting {mount_point}...")

            out, err = run_remote_command(vm_ip, f"sudo umount '{mount_point}'")
            if err:
                print(f"    Error: {err}")
                total_failed += 1
            else:
                print(f"    Success")
                total_succeeded += 1

    print(f"\nResult: {total_succeeded}/{total_mounts} unmount(s) succeeded.")
    if total_failed > 0:
        print(f"Warning: {total_failed} unmount(s) failed. Check if volumes are in use.")
        return False

    return True


def load_vm_mounts():
    """Load VM mount information from the mounts file (new format)."""
    if not os.path.exists(MOUNTS_FILE):
        print(f"Error: No saved mounts found at {MOUNTS_FILE}")
        print("Please run 'unmount' first to record existing mounts.")
        return None

    with open(MOUNTS_FILE, "r") as f:
        vm_mounts = json.load(f)

    total_mounts = sum(len(vm_data.get("mounts", [])) for vm_data in vm_mounts.values())
    print(f"Loaded mount info for {len(vm_mounts)} VM(s) ({total_mounts} total mount(s)) from {MOUNTS_FILE}")
    return vm_mounts


def verify_remote_dns_reachable(host):
    """Check if the NFS domain is reachable from a remote host."""
    _, err = run_remote_command(host, f"ping -c 1 {CRUSOE_NFS_DOMAIN}")
    return err is None


def do_remount(auto_confirm):
    """Remount mode: remount saved volumes using DNS on all VMs."""
    # Load saved VM mounts
    vm_mounts = load_vm_mounts()
    if vm_mounts is None:
        return False

    if len(vm_mounts) == 0:
        print("No VMs to process.")
        return True

    # Count total mounts and check current state on each VM
    total_to_restore = 0
    vms_to_process = {}

    print("\n" + "-" * 70)
    print("Checking current mount state on all VMs...")
    print("-" * 70)

    for vm_name, vm_data in vm_mounts.items():
        vm_ip = vm_data.get("ip")
        saved_mounts = vm_data.get("mounts", [])

        if not vm_ip:
            print(f"\n[{vm_name}] No IP address saved, skipping")
            continue

        if len(saved_mounts) == 0:
            print(f"\n[{vm_name}] ({vm_ip}) - No mounts saved")
            continue

        print(f"\n[{vm_name}] ({vm_ip})")

        # Get current mounts on this VM
        current_mounts = get_remote_mounts(vm_ip)
        if current_mounts is None:
            current_mounts = []

        current_mount_points = {m["mount_point"] for m in current_mounts}
        mounts_to_restore = [m for m in saved_mounts if m["mount_point"] not in current_mount_points]
        already_mounted = [m for m in saved_mounts if m["mount_point"] in current_mount_points]

        if already_mounted:
            print(f"  Already mounted (will skip): {len(already_mounted)}")
            for mount in already_mounted:
                print(f"    - {mount['volume_id']} at {mount['mount_point']}")

        if mounts_to_restore:
            print(f"  To restore: {len(mounts_to_restore)}")
            for mount in mounts_to_restore:
                print(f"    - {mount['volume_id']} at {mount['mount_point']}")
            vms_to_process[vm_name] = {
                "ip": vm_ip,
                "mounts": mounts_to_restore
            }
            total_to_restore += len(mounts_to_restore)
        else:
            print(f"  All volumes already mounted")

    print("\n" + "-" * 70)
    print(f"Total: {total_to_restore} mount(s) to restore across {len(vms_to_process)} VM(s)")
    print("-" * 70)

    if total_to_restore == 0:
        print("\nAll volumes are already mounted on all VMs.")
        return True

    if not auto_confirm:
        response = input(f"This will remount {total_to_restore} volume(s) using {CRUSOE_NFS_DOMAIN}. Continue? (y/N) ")
        if response.lower() != "y":
            print("Operation canceled.")
            return False

    # Remount on each VM
    total_failed = 0
    total_succeeded = 0

    for vm_name, vm_data in vms_to_process.items():
        vm_ip = vm_data["ip"]
        mounts = vm_data["mounts"]

        print(f"\n[{vm_name}] ({vm_ip}) - Remounting {len(mounts)} volume(s)...")

        # Verify DNS reachable from this VM
        print(f"  Verifying NFS server is reachable...")
        if not verify_remote_dns_reachable(vm_ip):
            print(f"  Error: Cannot reach {CRUSOE_NFS_DOMAIN} from this VM")
            total_failed += len(mounts)
            continue
        print(f"  NFS server is reachable")

        for mount in mounts:
            mount_point = mount["mount_point"]
            volume_id = mount["volume_id"]

            print(f"  Mounting {volume_id} at {mount_point}...")

            # Ensure mount point directory exists
            out, err = run_remote_command(vm_ip, f"sudo mkdir -p '{mount_point}'")
            if err:
                print(f"    Error creating mount point: {err}")
                total_failed += 1
                continue

            mount_cmd = (
                f"sudo mount -o vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns "
                f"{CRUSOE_NFS_DOMAIN}:/volumes/{volume_id} '{mount_point}'"
            )
            out, err = run_remote_command(vm_ip, mount_cmd, timeout=60)
            if err:
                print(f"    Error: {err}")
                total_failed += 1
            else:
                print(f"    Success")
                total_succeeded += 1

    print(f"\nResult: {total_succeeded}/{total_to_restore} remount(s) succeeded.")

    if total_failed > 0:
        print(f"Warning: {total_failed} remount(s) failed.")

    # Show current mounts on each VM
    print("\n" + "-" * 70)
    print("Current NFS mounts on all VMs:")
    print("-" * 70)
    for vm_name, vm_data in vm_mounts.items():
        vm_ip = vm_data.get("ip")
        if not vm_ip:
            continue
        print(f"\n[{vm_name}] ({vm_ip}):")
        out, err = run_remote_command(vm_ip, "findmnt -t nfs")
        if err:
            print(f"  Could not list mounts: {err}")
        else:
            if out:
                for line in out.split("\n"):
                    print(f"  {line}")
            else:
                print("  (none)")
    print("-" * 70)

    if total_failed == 0:
        print(f"\nNote: {MOUNTS_FILE} preserved for rollback if needed.")
        print("Run 'rollback' to revert to IP-based mounts, or delete the file manually.")

    return total_failed == 0


def do_rollback(auto_confirm):
    """Rollback mode: unmount DNS-based mounts and remount using saved IPs on all VMs."""
    vm_mounts = load_vm_mounts()
    if vm_mounts is None:
        return False

    if len(vm_mounts) == 0:
        print("No VMs to process.")
        return True

    # Count total mounts with IPs and check current state on each VM
    total_to_rollback = 0
    vms_to_process = {}

    print("\n" + "-" * 70)
    print("Checking mounts to rollback on all VMs...")
    print("-" * 70)

    for vm_name, vm_data in vm_mounts.items():
        vm_ip = vm_data.get("ip")
        saved_mounts = vm_data.get("mounts", [])

        if not vm_ip:
            print(f"\n[{vm_name}] No IP address saved, skipping")
            continue

        # Filter to mounts that have original IP addresses saved
        mounts_with_ips = [m for m in saved_mounts if m.get("ip_address")]

        if len(mounts_with_ips) == 0:
            print(f"\n[{vm_name}] ({vm_ip}) - No mounts with saved IPs")
            continue

        if len(mounts_with_ips) < len(saved_mounts):
            print(f"\n[{vm_name}] ({vm_ip}) - Warning: {len(saved_mounts) - len(mounts_with_ips)} mount(s) missing IP addresses")

        print(f"\n[{vm_name}] ({vm_ip})")

        # Get current mounts on this VM
        current_mounts = get_remote_mounts(vm_ip)
        if current_mounts is None:
            current_mounts = []

        current_mount_points = {m["mount_point"] for m in current_mounts}

        print(f"  Mounts to rollback: {len(mounts_with_ips)}")
        for mount in mounts_with_ips:
            status = "(currently mounted)" if mount["mount_point"] in current_mount_points else "(not mounted)"
            print(f"    - {mount['volume_id']} at {mount['mount_point']} {status}")
            print(f"      Original IP: {mount['ip_address']}")

        vms_to_process[vm_name] = {
            "ip": vm_ip,
            "mounts": mounts_with_ips,
            "current_mount_points": current_mount_points
        }
        total_to_rollback += len(mounts_with_ips)

    print("\n" + "-" * 70)
    print(f"Total: {total_to_rollback} mount(s) to rollback across {len(vms_to_process)} VM(s)")
    print("-" * 70)

    if total_to_rollback == 0:
        print("\nNo mounts to rollback.")
        return True

    if not auto_confirm:
        response = input(f"This will rollback {total_to_rollback} volume(s) to IP-based mounts. Continue? (y/N) ")
        if response.lower() != "y":
            print("Operation canceled.")
            return False

    # Rollback on each VM
    total_failed = 0
    total_succeeded = 0

    for vm_name, vm_data in vms_to_process.items():
        vm_ip = vm_data["ip"]
        mounts = vm_data["mounts"]
        current_mount_points = vm_data["current_mount_points"]

        print(f"\n[{vm_name}] ({vm_ip}) - Rolling back {len(mounts)} volume(s)...")

        # First unmount any currently mounted volumes
        unmount_failed = False
        for mount in mounts:
            mount_point = mount["mount_point"]
            if mount_point in current_mount_points:
                print(f"  Unmounting {mount_point}...")
                out, err = run_remote_command(vm_ip, f"sudo umount '{mount_point}'")
                if err:
                    print(f"    Error: {err}")
                    print(f"    Skipping remaining mounts on this VM")
                    unmount_failed = True
                    total_failed += len(mounts)
                    break
                print(f"    Success")

        if unmount_failed:
            continue

        # Remount using original IPs
        for mount in mounts:
            mount_point = mount["mount_point"]
            volume_id = mount["volume_id"]
            ip_address = mount["ip_address"]
            options = mount.get("options", "")

            # Remove DNS-specific mount options that shouldn't be used with IP-based mounts
            if options:
                opts = options.split(",")
                opts = [o for o in opts if not o.startswith("x-systemd.") and o != "remoteports=dns"]
                options = ",".join(opts)

            print(f"  Mounting {volume_id} at {mount_point} using {ip_address}...")

            # Ensure mount point directory exists
            out, err = run_remote_command(vm_ip, f"sudo mkdir -p '{mount_point}'")
            if err:
                print(f"    Error creating mount point: {err}")
                total_failed += 1
                continue

            # Use original options if available, otherwise use basic options
            if options:
                mount_cmd = f"sudo mount -o {options} {ip_address}:/volumes/{volume_id} '{mount_point}'"
            else:
                mount_cmd = f"sudo mount -t nfs {ip_address}:/volumes/{volume_id} '{mount_point}'"

            out, err = run_remote_command(vm_ip, mount_cmd, timeout=60)
            if err:
                print(f"    Error: {err}")
                total_failed += 1
            else:
                print(f"    Success")
                total_succeeded += 1

    print(f"\nResult: {total_succeeded}/{total_to_rollback} rollback mount(s) succeeded.")

    if total_failed > 0:
        print(f"Warning: {total_failed} rollback mount(s) failed.")

    # Show current mounts on each VM
    print("\n" + "-" * 70)
    print("Current NFS mounts on all VMs:")
    print("-" * 70)
    for vm_name, vm_data in vm_mounts.items():
        vm_ip = vm_data.get("ip")
        if not vm_ip:
            continue
        print(f"\n[{vm_name}] ({vm_ip}):")
        out, err = run_remote_command(vm_ip, "findmnt -t nfs")
        if err:
            print(f"  Could not list mounts: {err}")
        else:
            if out:
                for line in out.split("\n"):
                    print(f"  {line}")
            else:
                print("  (none)")
    print("-" * 70)

    return total_failed == 0


def process_fstab_content(content):
    """Process fstab content and return (new_lines, nfs_count)."""
    lines = content.split("\n")
    new_lines = []
    nfs_count = 0

    for line in lines:
        # Preserve comments and empty lines
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            new_lines.append(line)
            continue

        parts = line.split()
        if len(parts) < 4:
            new_lines.append(line)
            continue

        # Check if this is an NFS mount
        fs_type = parts[2] if len(parts) > 2 else ""
        if fs_type != "nfs":
            new_lines.append(line)
            continue

        source = parts[0]
        mount_point = parts[1]

        # Check if it's a Crusoe NFS mount that needs migration
        if ":/volumes/" not in source:
            new_lines.append(line)
            continue

        # Check if already using DNS
        if source.startswith(CRUSOE_NFS_DOMAIN):
            new_lines.append(line)
            continue

        # Extract volume ID and create new line
        volume_id = source.split(":/volumes/")[1]
        new_line = (
            f"{CRUSOE_NFS_DOMAIN}:/volumes/{volume_id} {mount_point} "
            f"nfs vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=30 0 0"
        )
        new_lines.append(new_line)
        nfs_count += 1

    return new_lines, nfs_count


def update_fstab(auto_confirm):
    """Update /etc/fstab to use DNS instead of IP-based mounts on all VMs."""
    # Load VMs from icat-vms.json
    vms = load_vms()
    if vms is None:
        return False

    if len(vms) == 0:
        print("No VMs to process.")
        return True

    # Collect fstab info from all VMs
    vms_to_update = {}
    total_nfs_entries = 0

    print("\n" + "-" * 70)
    print("Checking /etc/fstab on all VMs...")
    print("-" * 70)

    for vm in vms:
        vm_name = vm["name"]
        vm_ip = vm["public_ip"]

        print(f"\n[{vm_name}] ({vm_ip})")

        out, err = run_remote_command(vm_ip, "cat /etc/fstab")
        if err:
            print(f"  Error reading /etc/fstab: {err}")
            continue

        new_lines, nfs_count = process_fstab_content(out)

        if nfs_count == 0:
            print(f"  No fstab entries need to be migrated")
        else:
            print(f"  {nfs_count} NFS entry/entries to migrate")
            vms_to_update[vm_name] = {
                "ip": vm_ip,
                "original": out,
                "new_lines": new_lines,
                "nfs_count": nfs_count
            }
            total_nfs_entries += nfs_count

    print("\n" + "-" * 70)
    print(f"Total: {total_nfs_entries} fstab entry/entries to update across {len(vms_to_update)} VM(s)")
    print("-" * 70)

    if total_nfs_entries == 0:
        print("\nNo fstab entries need to be migrated on any VM.")
        return True

    # Show detailed changes for each VM
    for vm_name, vm_data in vms_to_update.items():
        print(f"\n[{vm_name}] ({vm_data['ip']}) - {vm_data['nfs_count']} entry/entries to update:")
        print("-" * 40)
        print("Original:")
        for line in vm_data["original"].split("\n"):
            if ":/volumes/" in line and not line.startswith(CRUSOE_NFS_DOMAIN):
                print(f"  {line}")
        print("New:")
        for line in vm_data["new_lines"]:
            if CRUSOE_NFS_DOMAIN in line:
                print(f"  {line}")
        print("-" * 40)

    if not auto_confirm:
        response = input(f"\nUpdate fstab on {len(vms_to_update)} VM(s)? (y/N) ")
        if response.lower() != "y":
            print("fstab update canceled.")
            return False

    # Update fstab on each VM
    total_failed = 0
    total_succeeded = 0

    for vm_name, vm_data in vms_to_update.items():
        vm_ip = vm_data["ip"]
        new_lines = vm_data["new_lines"]

        print(f"\n[{vm_name}] ({vm_ip}) - Updating /etc/fstab...")

        # Create new fstab content
        new_content = "\n".join(new_lines)
        if not new_content.endswith("\n"):
            new_content += "\n"

        # Write to temp file on remote host and copy to /etc/fstab
        # Use base64 encoding to safely transfer content
        encoded_content = base64.b64encode(new_content.encode()).decode()

        update_cmd = (
            f"echo '{encoded_content}' | base64 -d > /tmp/fstab.new && "
            f"sudo cp /tmp/fstab.new /etc/fstab && "
            f"rm /tmp/fstab.new"
        )

        out, err = run_remote_command(vm_ip, update_cmd)
        if err:
            print(f"  Error: {err}")
            total_failed += 1
        else:
            print(f"  Success")
            total_succeeded += 1

    print(f"\nResult: {total_succeeded}/{len(vms_to_update)} fstab update(s) succeeded.")

    if total_failed > 0:
        print(f"Warning: {total_failed} fstab update(s) failed.")

    return total_failed == 0


def do_list_vms(project_id, auto_confirm):
    """List VMs in eu-iceland1-a location and save to file for review."""
    # Step a: Create ./crusoe directory
    ensure_crusoe_dir()

    # Step b: Get VMs from Crusoe CLI
    print(f"\nFetching VMs for project {project_id}...")
    out, err = run_command(
        f"crusoe compute vms list --project-id {project_id} -f json",
        timeout=60
    )
    if err:
        print(f"Error fetching VMs: {err}")
        return False

    if not out:
        print("No VMs found.")
        return True

    try:
        vms_json = json.loads(out)
    except json.JSONDecodeError as e:
        print(f"Error parsing VM list: {e}")
        return False

    # Step c: Filter VMs by location and extract name/public IP
    filtered_vms = []
    for vm in vms_json:
        location = vm.get("location", "")
        if location != TARGET_LOCATION:
            continue

        vm_name = vm.get("name", "")
        vm_id = vm.get("id", "")
        public_ip = None

        # Extract public IP from network interfaces
        for nic in vm.get("network_interfaces", []):
            for ip_info in nic.get("ips", []):
                public_ipv4 = ip_info.get("public_ipv4", {})
                if public_ipv4 and public_ipv4.get("address"):
                    public_ip = public_ipv4["address"]
                    break
            if public_ip:
                break

        # Only include VMs that have public IPs (i.e., are running)
        if public_ip:
            filtered_vms.append({
                "name": vm_name,
                "id": vm_id,
                "public_ip": public_ip,
                "location": location
            })

    if len(filtered_vms) == 0:
        print(f"No running VMs found in {TARGET_LOCATION} location.")
        return True

    # Step d: Display VMs to user
    print("\n" + "-" * 70)
    print(f"VMs in {TARGET_LOCATION} location:")
    print("-" * 70)
    for i, vm in enumerate(filtered_vms, 1):
        ip_display = vm["public_ip"] if vm["public_ip"] else "(no public IP)"
        print(f"  {i}. {vm['name']}")
        print(f"     Public IP: {ip_display}")
        print()
    print("-" * 70)
    print(f"Total: {len(filtered_vms)} VM(s)")

    # Step e: Save to file
    with open(ICAT_VMS_FILE, "w") as f:
        json.dump(filtered_vms, f, indent=2)
    print(f"\nSaved VM list to {ICAT_VMS_FILE}")

    # Step f: Ask user to review and modify if needed
    if not auto_confirm:
        print("\nPlease review the VM list above.")
        print(f"You can edit {ICAT_VMS_FILE} to remove VMs you don't want to include.")
        response = input("Press Enter when done reviewing, or 'c' to cancel: ")
        if response.lower() == "c":
            print("Operation canceled.")
            return False

        # Reload the file in case user modified it
        try:
            with open(ICAT_VMS_FILE, "r") as f:
                modified_vms = json.load(f)
            if len(modified_vms) != len(filtered_vms):
                print(f"\nVM list updated: {len(modified_vms)} VM(s) remaining.")
        except Exception as e:
            print(f"Warning: Could not reload VM list: {e}")

    print(f"\nVM list is ready at {ICAT_VMS_FILE}")
    return True


def do_verify_mounts():
    """Verify NFS mounts on all VMs, testing read and write access."""
    # Load VMs from icat-vms.json
    vms = load_vms()
    if vms is None:
        return False

    if len(vms) == 0:
        print("No VMs to process.")
        return True

    # Prepare output file
    results = []
    header = f"{'HOST':<30} {'COUNT':<6} {'READ':<6} {'WRITE':<6} MOUNT_POINTS"
    separator = f"{'----':<30} {'-----':<6} {'----':<6} {'-----':<6} ------------"
    results.append(header)
    results.append(separator)

    print("\n" + "-" * 70)
    print("Verifying NFS mounts on all VMs...")
    print("-" * 70)

    for vm in vms:
        vm_name = vm["name"]
        vm_ip = vm["public_ip"]

        print(f"\n[{vm_name}] ({vm_ip})")

        # Check SSH connectivity first
        _, err = run_remote_command(vm_ip, "echo ok", timeout=15)
        if err:
            print(f"  Connection failed: {err}")
            results.append(f"{vm_name:<30} {'ERROR':<6} {'-':<6} {'-':<6} connection failed")
            continue

        # Get NFS mounts and test read/write on remote host
        # We run a single SSH command that does all the testing to minimize connections
        test_script = f'''
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
    if timeout {NFS_TEST_TIMEOUT} ls "$mount" >/dev/null 2>&1; then
        r="R"
        read_ok=$((read_ok + 1))
    else
        r="-"
    fi

    # Write test: try to create and remove a temp file (with timeout for hung NFS)
    testfile="$mount/.tmp_crusoe_nfs_verify_test_$$"
    if timeout {NFS_TEST_TIMEOUT} touch "$testfile" 2>/dev/null && timeout {NFS_TEST_TIMEOUT} rm -f "$testfile" 2>/dev/null; then
        w="W"
        write_ok=$((write_ok + 1))
    else
        timeout {NFS_TEST_TIMEOUT} rm -f "$testfile" 2>/dev/null
        w="-"
    fi

    mount_status="${{mount_status}}${{mount}}(${{r}}${{w}}),"
done <<< "$mounts"

mount_status=${{mount_status%,}}
echo "${{count}}|${{read_ok}}|${{write_ok}}|${{mount_status}}"
'''

        out, err = run_remote_command(vm_ip, test_script, timeout=120)

        if err or not out:
            print(f"  Error running verification: {err}")
            results.append(f"{vm_name:<30} {'ERROR':<6} {'-':<6} {'-':<6} verification failed")
            continue

        # Parse result
        parts = out.strip().split("|")
        if len(parts) != 4:
            print(f"  Unexpected output format: {out}")
            results.append(f"{vm_name:<30} {'ERROR':<6} {'-':<6} {'-':<6} parse error")
            continue

        count, read_ok, write_ok, mount_status = parts

        if count == "0":
            print(f"  No NFS mounts found")
        else:
            print(f"  Found {count} NFS mount(s): {read_ok} readable, {write_ok} writable")
            print(f"  Details: {mount_status}")

        results.append(f"{vm_name:<30} {count:<6} {read_ok:<6} {write_ok:<6} {mount_status}")

    # Write results to file
    with open(VERIFY_OUTPUT_FILE, "w") as f:
        f.write("\n".join(results) + "\n")

    print("\n" + "-" * 70)
    print(f"Results written to {VERIFY_OUTPUT_FILE}")
    print("-" * 70)

    # Also display the results
    print("\n" + "\n".join(results))

    print(f"""
Legend: R=read OK, W=write OK, -=failed or timed out
READ/WRITE columns show count of mounts that passed each test
NFS_TEST_TIMEOUT: {NFS_TEST_TIMEOUT}s""")

    return True


def main():
    parser = argparse.ArgumentParser(
        description=f"Migrate NFS mounts to {CRUSOE_NFS_DOMAIN}."
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # Unmount subcommand
    unmount_parser = subparsers.add_parser(
        "unmount",
        help="Record current NFS mounts and unmount them"
    )
    unmount_parser.add_argument(
        "-y", action="store_true",
        help="Auto-confirm without prompting"
    )

    # Remount subcommand
    remount_parser = subparsers.add_parser(
        "remount",
        help="Remount saved volumes using DNS"
    )
    remount_parser.add_argument(
        "-y", action="store_true",
        help="Auto-confirm without prompting"
    )

    # Fstab subcommand
    fstab_parser = subparsers.add_parser(
        "fstab",
        help="Update /etc/fstab to use DNS instead of IP-based mounts"
    )
    fstab_parser.add_argument(
        "-y", action="store_true",
        help="Auto-confirm without prompting"
    )

    # Rollback subcommand
    rollback_parser = subparsers.add_parser(
        "rollback",
        help="Rollback to IP-based mounts using saved mount info"
    )
    rollback_parser.add_argument(
        "-y", action="store_true",
        help="Auto-confirm without prompting"
    )

    # List-vms subcommand
    list_vms_parser = subparsers.add_parser(
        "list-vms",
        help="List VMs in eu-iceland1-a location with public IPs"
    )
    list_vms_parser.add_argument(
        "project_id",
        help="Crusoe project ID"
    )
    list_vms_parser.add_argument(
        "-y", action="store_true",
        help="Auto-confirm without prompting"
    )

    # Verify-mounts subcommand
    subparsers.add_parser(
        "verify-mounts",
        help="Verify NFS mounts on all VMs, testing read and write access"
    )

    # Help subcommand
    subparsers.add_parser(
        "help",
        help="Show detailed usage instructions"
    )

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(1)

    if args.command == "help":
        print(__doc__)
        sys.exit(0)
    elif args.command == "unmount":
        success = do_unmount(args.y)
    elif args.command == "remount":
        success = do_remount(args.y)
    elif args.command == "fstab":
        success = update_fstab(args.y)
    elif args.command == "rollback":
        success = do_rollback(args.y)
    elif args.command == "list-vms":
        success = do_list_vms(args.project_id, args.y)
    elif args.command == "verify-mounts":
        success = do_verify_mounts()
    else:
        parser.print_help()
        sys.exit(1)

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()