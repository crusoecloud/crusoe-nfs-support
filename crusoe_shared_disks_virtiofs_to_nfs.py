"""
This script will do the following:

1) Validate that the NFS IPs are pingable.
2) For every Virtiofs mount on the VM, unmount it and remount it as NFS.
3) For every Virtiofs mount in /etc/fstab, replace it with the respective NFS mount.

If you have any questions, don't hesitate to reach out to Crusoe support.

"""
import argparse
import subprocess
import sys
import json
import uuid
import time

# START statics
# these start and end IPs are used to connect to Crusoe's NFS servers
start_ip = "100.64.0.2"
end_ip = "100.64.0.17"
# END statics

def run_command(command):
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True, shell=True, timeout=5)
        return result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired as e:
        return None, e
    except subprocess.CalledProcessError as e:
        return None, e
    except Exception as e:
        return None, e.stderr
def is_valid_uuid(uuid_string):
    try:
        uuid.UUID(str(uuid_string))
        return True
    except ValueError:
        return False
def get_name_to_id_mapping(name_ids):
    name_ids_pairs = name_ids.split('+')
    name_to_id = {}
    for name_id_pair in name_ids_pairs:
        if "," not in name_id_pair:
            return None, f"missing comma for {name_id_pair}; see -h for more details"
        name_and_id = name_id_pair.split(",")
        name = name_and_id[0]
        uuid = name_and_id[1]
        if not is_valid_uuid(uuid):
            return None, f"invalid disk UUID for name {name}: '{uuid}'"
        name_to_id[name] = uuid

    return name_to_id, ""
def get_current_mounts():
    out, err = run_command("findmnt -t virtiofs --json")
    if err:
        print(f"something went wrong: {out} {err}")
        return
    mounts_json = json.loads(out)

    mounts = []
    for target in mounts_json["filesystems"]:
        mounts.append((target["target"], target["source"]))

    return mounts
def verify_all_mounts_exist(mounts, name_to_id):
    out, err = run_command(f"showmount -e {start_ip}")
    if err:
        print(f"Error: could not find any mounts for this VM: {err}")
        return False
    for _, disk_name in mounts:
        if disk_name not in name_to_id:
            return False
        volume_id = name_to_id[disk_name]
        if f"/volumes/{volume_id}" not in out:
            return False
    return True
def verify_ping():
    _, err = run_command(f"ping -c 1 {start_ip}")
    if err:
        return False
    _, err = run_command(f"ping -c 1 {end_ip}")
    if err:
        return False
    return True
def remount_virtiofs_mounts(name_to_id, auto_confirm):
    mounts = get_current_mounts()

    print("Verifying NFS server can be reached...")
    if not verify_ping():
        print(f"Error: could not reach NFS server")
        return
    
    if len(mounts) == 0:
        print("There are no virtiofs mounts that need to be remounted to NFS.")
        return True

    print(" ----------------------------------------------------------------------------------------------- ")
    for mount_dir, disk_name in mounts:
        print(f"\t{disk_name} on {mount_dir} is currently VIRTIOFS")
    print(" ----------------------------------------------------------------------------------------------- ")
    if not auto_confirm:
        key_press = input(f"There are {len(mounts)} virtiofs mount(s) that will be converted to NFS. Continue? (y/N) ")
        if key_press.lower() != "y":
            print("User did not specify (y), so the operation was canceled")
            return

    failed_count = 0
    for mount_dir, disk_name in mounts:
        def print_err_and_remount(out, err):
            out_format = f"{out} " if out else ""
            err_format = err if err else ""
            print(f"\tunmount failed, is it currently in use? details: {out_format}{err_format}")
            # attempt to remount
            out, err = run_command(f"sudo mount -t virtiofs '{disk_name}' '{mount_dir}'")
            if err:
                print(f"attempt to remount failed: {err}")

        print(f"attempting to remount {mount_dir} from virtiofs to NFS...")
        # attempt up to 5 times
        out, err = run_command(f"sudo umount '{mount_dir}'")
        if err:
            print_err_and_remount(out, err)
            time.sleep(0.2)
            failed_count += 1
        else:
            num_retries = 5
            for i in range(num_retries):
                successful_mount_message = "mount was successful!"
                out, err = run_command(f"sudo mount -o vers=3,nconnect=16,spread_reads,spread_writes,remoteports={start_ip}-{end_ip} {start_ip}:/volumes/{name_to_id[disk_name]} '{mount_dir}' && echo '{successful_mount_message}'")
                if err and (not out or successful_mount_message not in out):
                    if i == num_retries - 1:
                        print_err_and_remount(out, err)
                        failed_count += 1
                else:
                    print(f"\tremount succeeded.")
                    break
    
    print(f"RESULT: {len(mounts) - failed_count} mount(s) succeeded.")
    if failed_count > 0:
        print(f"Error: {failed_count} mount(s) failed. Please re-run this script after resolving the issues.")
    return failed_count == 0
    
def remount_fstab_mounts(name_to_id, auto_confirm):
    out, err = run_command("sudo cat /etc/fstab")
    if err:
        print(f"Checking fstab file contents failed: {err}")
        return
    
    out_lines = out.split("\n")
    if len(out_lines) < 2:
        print("There are no fstab mounts to convert from virtiofs to NFS.")
        return

    new_lines = out_lines[:]
    virtiofs_mount_count = 0
    for i in range(1, len(out_lines)):
        old_line = out_lines[i]
        mount_options = old_line.split()
        mount_dir = mount_options[1]
        disk_name = mount_options[0]
        if len(mount_options) < 6:
            print(f"WARNING: could not parse fstab line {old_line}")
            continue
        if mount_options[2] == "virtiofs":
            virtiofs_mount_count += 1
            if disk_name not in name_to_id:
                print(f"Error: cannot find volume ID for {disk_name}")
                continue

            new_lines[i] = f"{start_ip}:/volumes/{name_to_id[disk_name]} {mount_dir} nfs vers=3,nconnect=16,spread_reads,spread_writes,remoteports={start_ip}-{end_ip} 0 0"    
    if virtiofs_mount_count == 0:
        print("There are no fstab mounts to convert from virtiofs to NFS.")
        return
    
    print(" --------------------------------------------------------------- ")
    print(" ORIGINAL MOUNT FILE")
    print(" --------------------------------------------------------------- ")
    for line in out_lines:
        print(line)
    print(" --------------------------------------------------------------- ")
    print(" NEW MOUNT FILE")
    print(" --------------------------------------------------------------- ")
    for line in new_lines:
        print(line)
    print(" --------------------------------------------------------------- ")
    if not auto_confirm:
        key_press = input(f"The new mount options will be applied to your /etc/fstab file. Continue? (y/N) ")
        if key_press.lower() != "y":
            print("User did not specify (y), so the operation was canceled")
            return

    lines_combined = "\n".join(new_lines)
    out, err = run_command(f"echo '{lines_combined}' | sudo sh -c 'cat > /etc/fstab'")
    if err:
        print(f"Error: error when replacing fstab file: {err}")
        return
    else:
        print("Changes have been applied successfully.")

def do_main():
    parser = argparse.ArgumentParser(
        description="Remount each disk from virtiofs to NFS, as applicable."
    )
    parser.add_argument(
        "-n", "--name-ids",
        type=str,
        default=None,
        help='A string containing DISK_NAME,DISK_ID pairs separated by + (e.g., "disk-1,00000000-0000-0000-0000-000000000000+disk-2,00000000-0000-0000-0000-000000000000").'
    )
    parser.add_argument('-y', action='store_true', help="A flag to confirm an action.")

    args = parser.parse_args()

    if not args.name_ids:
        print("Error: you must specify --name-ids. See -h for more details", file=sys.stderr)
        return
    name_to_id, err = get_name_to_id_mapping(args.name_ids)
    if err:
        print(f"Error: parsing input failed: {err}", file=sys.stderr)
        return

    auto_confirm = args.y
    succeeded = remount_virtiofs_mounts(name_to_id, auto_confirm)
    if succeeded:
        remount_fstab_mounts(name_to_id, auto_confirm)
if __name__ == "__main__":
    do_main()
