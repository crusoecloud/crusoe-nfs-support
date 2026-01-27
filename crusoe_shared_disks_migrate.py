"""
This script migrates NFS mounts from IP-based to DNS-based (nfs.crusoecloudcompute.com).

Usage:
    python crusoe_shared_disks_migrate.py help
        - Show this help message

    python crusoe_shared_disks_migrate.py unmount [-y]
        - Creates ./crusoe directory to store mount information
        - Records current NFS mounts (volume ID, mount point, IP address, options)
        - Unmounts all NFS mounts

    python crusoe_shared_disks_migrate.py remount [-y]
        - Remounts volumes recorded by 'unmount' using DNS

    python crusoe_shared_disks_migrate.py fstab [-y]
        - Updates /etc/fstab to use DNS instead of IP-based mounts

    python crusoe_shared_disks_migrate.py rollback [-y]
        - Rolls back to IP-based mounts using saved mount info

NFS Mount Options:
    IP-based mount (old):
        mount -t nfs <IP>:/volumes/<volume_id> /mount/point

    DNS-based mount (new):
        mount -o vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns \\
            nfs.crusoecloudcompute.com:/volumes/<volume_id> /mount/point

    Key differences:
        - DNS-based mounts use nfs.crusoecloudcompute.com instead of a specific IP
        - remoteports=dns enables DNS-based endpoint resolution for better load balancing
        - nconnect=16 creates multiple TCP connections for improved throughput
        - spread_reads,spread_writes distributes I/O across connections

    Example fstab entry (DNS-based):
        nfs.crusoecloudcompute.com:/volumes/<volume_id> /mount/point nfs vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns 0 0

If you have any questions, don't hesitate to reach out to Crusoe support.
"""

import argparse
import subprocess
import sys
import json
import os

# START statics
CRUSOE_NFS_DOMAIN = "nfs.crusoecloudcompute.com"
CRUSOE_DIR = "./crusoe"
MOUNTS_FILE = os.path.join(CRUSOE_DIR, "mounts.json")
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


def do_unmount(auto_confirm):
    """Unmount mode: create dir, record mounts, unmount all NFS."""
    # Step a: Create ./crusoe directory
    ensure_crusoe_dir()

    # Step b: Record mounted volumes
    mounts = get_current_mounts()
    if mounts is None:
        print("Error: Failed to get current mounts.")
        return False

    if len(mounts) == 0:
        # Don't overwrite existing mounts file if no mounts are currently found
        if os.path.exists(MOUNTS_FILE):
            print("No NFS mounts found. Existing mounts file preserved.")
            print(f"(If you want to clear the saved mounts, delete {MOUNTS_FILE})")
        else:
            print("No NFS mounts found to unmount.")
            save_mounts([])
        return True

    print("\n" + "-" * 70)
    print("Current NFS mounts:")
    print("-" * 70)
    for mount in mounts:
        print(f"  Volume: {mount['volume_id']}")
        print(f"  Mount point: {mount['mount_point']}")
        print(f"  IP address: {mount['ip_address']}")
        print()
    print("-" * 70)

    if not auto_confirm:
        response = input(f"This will unmount {len(mounts)} NFS mount(s). Continue? (y/N) ")
        if response.lower() != "y":
            print("Operation canceled.")
            return False

    # Save mounts before unmounting
    save_mounts(mounts)

    # Step c: Unmount all NFS mounts
    failed_count = 0
    for mount in mounts:
        mount_point = mount["mount_point"]
        print(f"Unmounting {mount_point}...")

        out, err = run_command(f"sudo umount '{mount_point}'")
        if err:
            print(f"  Error: {err}")
            failed_count += 1
        else:
            print(f"  Success")

    print(f"\nResult: {len(mounts) - failed_count}/{len(mounts)} unmount(s) succeeded.")
    if failed_count > 0:
        print(f"Warning: {failed_count} unmount(s) failed. Check if volumes are in use.")
        return False

    return True


def do_remount(auto_confirm):
    """Remount mode: remount saved volumes using DNS, update fstab."""
    # Step d: Remount all NFS mounts using DNS
    mounts = load_mounts()
    if mounts is None:
        return False

    if len(mounts) == 0:
        print("No mounts to remount.")
        return True

    # Check which mounts are already mounted
    current_mounts = get_current_mounts()
    if current_mounts is None:
        current_mounts = []

    current_mount_points = {m["mount_point"] for m in current_mounts}
    mounts_to_restore = [m for m in mounts if m["mount_point"] not in current_mount_points]
    already_mounted = [m for m in mounts if m["mount_point"] in current_mount_points]

    if already_mounted:
        print(f"\n{len(already_mounted)} volume(s) already mounted (will be skipped):")
        for mount in already_mounted:
            print(f"  - {mount['volume_id']} at {mount['mount_point']}")

    if len(mounts_to_restore) == 0:
        print("\nAll volumes are already mounted.")
        return True

    print("\nVerifying NFS server is reachable...")
    if not verify_dns_reachable():
        print(f"Error: Cannot reach {CRUSOE_NFS_DOMAIN}")
        return False
    print("NFS server is reachable.")

    print("\n" + "-" * 70)
    print("Mounts to restore:")
    print("-" * 70)
    for mount in mounts_to_restore:
        print(f"  Volume: {mount['volume_id']}")
        print(f"  Mount point: {mount['mount_point']}")
        print()
    print("-" * 70)

    if not auto_confirm:
        response = input(f"This will remount {len(mounts_to_restore)} volume(s) using {CRUSOE_NFS_DOMAIN}. Continue? (y/N) ")
        if response.lower() != "y":
            print("Operation canceled.")
            return False

    failed_count = 0
    for mount in mounts_to_restore:
        mount_point = mount["mount_point"]
        volume_id = mount["volume_id"]

        print(f"Mounting {volume_id} at {mount_point}...")

        # Ensure mount point directory exists
        if not os.path.exists(mount_point):
            out, err = run_command(f"sudo mkdir -p '{mount_point}'")
            if err:
                print(f"  Error creating mount point: {err}")
                failed_count += 1
                continue

        mount_cmd = (
            f"sudo mount -o vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns "
            f"{CRUSOE_NFS_DOMAIN}:/volumes/{volume_id} '{mount_point}'"
        )
        out, err = run_command(mount_cmd, timeout=30)
        if err:
            print(f"  Error: {err}")
            failed_count += 1
        else:
            print(f"  Success")

    print(f"\nResult: {len(mounts_to_restore) - failed_count}/{len(mounts_to_restore)} remount(s) succeeded.")

    if failed_count > 0:
        print(f"Warning: {failed_count} remount(s) failed.")

    # Show current mounts
    print("\n" + "-" * 70)
    print("Current NFS mounts:")
    print("-" * 70)
    out, err = run_command("findmnt -t nfs")
    if err:
        print(f"Could not list mounts: {err}")
    else:
        print(out if out else "(none)")
    print("-" * 70)

    if failed_count == 0:
        print(f"\nNote: {MOUNTS_FILE} preserved for rollback if needed.")
        print("Run 'rollback' to revert to IP-based mounts, or delete the file manually.")

    return failed_count == 0


def do_rollback(auto_confirm):
    """Rollback mode: unmount DNS-based mounts and remount using saved IPs."""
    mounts = load_mounts()
    if mounts is None:
        return False

    if len(mounts) == 0:
        print("No mounts to rollback.")
        return True

    # Check that we have IP addresses saved
    mounts_with_ips = [m for m in mounts if m.get("ip_address")]
    if len(mounts_with_ips) == 0:
        print("Error: No IP addresses saved in mounts file. Cannot rollback.")
        return False

    if len(mounts_with_ips) < len(mounts):
        print(f"Warning: {len(mounts) - len(mounts_with_ips)} mount(s) missing IP addresses.")

    # Check which mounts are currently mounted
    current_mounts = get_current_mounts()
    if current_mounts is None:
        current_mounts = []

    current_mount_points = {m["mount_point"] for m in current_mounts}

    print("\n" + "-" * 70)
    print("Mounts to rollback (remount using original IPs):")
    print("-" * 70)
    for mount in mounts_with_ips:
        status = "(currently mounted)" if mount["mount_point"] in current_mount_points else "(not mounted)"
        print(f"  Volume: {mount['volume_id']}")
        print(f"  Mount point: {mount['mount_point']} {status}")
        print(f"  Original IP: {mount['ip_address']}")
        print()
    print("-" * 70)

    if not auto_confirm:
        response = input(f"This will rollback {len(mounts_with_ips)} volume(s) to IP-based mounts. Continue? (y/N) ")
        if response.lower() != "y":
            print("Operation canceled.")
            return False

    # First unmount any currently mounted volumes
    for mount in mounts_with_ips:
        mount_point = mount["mount_point"]
        if mount_point in current_mount_points:
            print(f"Unmounting {mount_point}...")
            out, err = run_command(f"sudo umount '{mount_point}'")
            if err:
                print(f"  Error: {err}")
                print("Rollback aborted. Please unmount manually and try again.")
                return False
            print(f"  Success")

    # Remount using original IPs
    failed_count = 0
    for mount in mounts_with_ips:
        mount_point = mount["mount_point"]
        volume_id = mount["volume_id"]
        ip_address = mount["ip_address"]
        options = mount.get("options", "")

        print(f"Mounting {volume_id} at {mount_point} using {ip_address}...")

        # Ensure mount point directory exists
        if not os.path.exists(mount_point):
            out, err = run_command(f"sudo mkdir -p '{mount_point}'")
            if err:
                print(f"  Error creating mount point: {err}")
                failed_count += 1
                continue

        # Use original options if available, otherwise use basic options
        if options:
            mount_cmd = f"sudo mount -o {options} {ip_address}:/volumes/{volume_id} '{mount_point}'"
        else:
            mount_cmd = f"sudo mount -t nfs {ip_address}:/volumes/{volume_id} '{mount_point}'"

        out, err = run_command(mount_cmd, timeout=30)
        if err:
            print(f"  Error: {err}")
            failed_count += 1
        else:
            print(f"  Success")

    print(f"\nResult: {len(mounts_with_ips) - failed_count}/{len(mounts_with_ips)} rollback mount(s) succeeded.")

    if failed_count > 0:
        print(f"Warning: {failed_count} rollback mount(s) failed.")

    # Show current mounts
    print("\n" + "-" * 70)
    print("Current NFS mounts:")
    print("-" * 70)
    out, err = run_command("findmnt -t nfs")
    if err:
        print(f"Could not list mounts: {err}")
    else:
        print(out if out else "(none)")
    print("-" * 70)

    return failed_count == 0


def update_fstab(auto_confirm):
    """Update /etc/fstab to use DNS instead of IP-based mounts."""
    print("\n" + "-" * 70)
    print("Updating /etc/fstab...")
    print("-" * 70)

    out, err = run_command("cat /etc/fstab")
    if err:
        print(f"Error reading /etc/fstab: {err}")
        return False

    lines = out.split("\n")
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
            f"nfs vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns 0 0"
        )
        new_lines.append(new_line)
        nfs_count += 1

    if nfs_count == 0:
        print("No fstab entries need to be migrated.")
        return True

    print("\nOriginal /etc/fstab:")
    print("-" * 40)
    for line in lines:
        print(line)
    print("-" * 40)

    print("\nNew /etc/fstab:")
    print("-" * 40)
    for line in new_lines:
        print(line)
    print("-" * 40)

    if not auto_confirm:
        response = input(f"\nUpdate {nfs_count} NFS entry/entries in /etc/fstab? (y/N) ")
        if response.lower() != "y":
            print("fstab update canceled.")
            return False

    # Write new fstab using a temp file for safety
    new_content = "\n".join(new_lines)
    temp_file = "/tmp/fstab.new"

    # Write to temp file
    try:
        with open(temp_file, "w") as f:
            f.write(new_content)
            if not new_content.endswith("\n"):
                f.write("\n")
    except Exception as e:
        print(f"Error writing temp file: {e}")
        return False

    # Copy temp file to /etc/fstab
    out, err = run_command(f"sudo cp {temp_file} /etc/fstab")
    if err:
        print(f"Error updating /etc/fstab: {err}")
        return False

    print("Successfully updated /etc/fstab")
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
    else:
        parser.print_help()
        sys.exit(1)

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
