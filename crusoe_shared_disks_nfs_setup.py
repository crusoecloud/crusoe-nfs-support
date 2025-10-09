"""
This script will do the following:

1) download and install NFS drivers for the specific kernel version.
2) activate NFS drivers
3) update read-ahead cache automatically to 16MB, and update ring buffer recommended settings
4) apply network configuration optimizations

If you have any questions, don't hesitate to reach out to Crusoe support.

"""
import subprocess
import argparse
import sys

NFS_PACKAGE_URL = "https://github.com/crusoecloud/crusoe-nfs-support/raw/refs/heads/main/vastnfs-dkms_4.0.35-vastdata_all.deb"

def run_command(command, timeout=5):
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True, shell=True, timeout=timeout)
        # return error only if error code is non-zero
        return result.stdout.strip(), result.stderr.strip() if result.returncode != 0 else None
    except subprocess.TimeoutExpired as e:
        return None, e
    except subprocess.CalledProcessError as e:
        return None, e
    except Exception as e:
        return None, e.stderr
def manually_install_VAST_NFS_driver(auto_confirm = False):
    if not auto_confirm:
        key_press = input(f"IMPORTANT: The NFS driver will be installed. \n\tThis requires installing a few packages (dkms nfs-common).\n\tContinue? (y/N) ")
        if key_press.lower() != "y":
            print("User did not specify (y), so the operation was canceled")
            return ""
    
    print("Downloading NFS driver debian package...")
    _, err = run_command(f"cd /tmp && wget -O /tmp/crusoe_nfs.deb {NFS_PACKAGE_URL}", 300)
    if err:
        print(f"ERROR: something went wrong when downloading the driver: {err}")
        return err
    
    print("Installing dependencies (this may take a few minutes)...")
    _, err = run_command("sudo apt-get update && sudo apt-get -y install dkms nfs-common", 600)
    if err:
        print(f"ERROR: something went wrong when installing dependencies: {err}")
        return err

    print("Installing the NFS driver (this may take a while)...")
    _, err = run_command(f"sudo dpkg -i /tmp/crusoe_nfs.deb", 600)
    if err:
        print(f"ERROR: something went wrong when manually installing the driver: {err}")
        return err
    
    print("The NFS driver has been installed!")
def check_if_VAST_NFS_driver_installed():
    out, err = run_command("dpkg -l | grep vastnfs")
    if err:
        return False, err
    if out and "vastnfs-modules" in out:
        return True, None
    return False, None
def install_VAST_NFS_driver(auto_confirm = False):
    installed, err = check_if_VAST_NFS_driver_installed()
    if installed:
        print("The NFS driver has already been installed.")
        return True
    
    """
    Find kernel version
    Install driver
    Reload the driver
    Success
    """
    kernel_version, err = run_command("uname -r")
    if err:
        print(f"ERROR: could not find kernel version: {err}")
    print(f"Your VM's kernel version is: {kernel_version}")

    if kernel_version:
        err = manually_install_VAST_NFS_driver(auto_confirm)
        if err:
            print("Something went wrong when manually installing the NFS driver.")
            return

    print("Enabling NFS drivers...")
    _, err = run_command("sudo update-initramfs -u -k `uname -r` && sudo vastnfs-ctl reload", 300)
    if err:
        print(f"ERROR: could not reload NFS drivers, please report this to the Crusoe team: {err}")
    
    print("the NFS drivers have been installed and enabled!")
    return True
def update_read_ahead_cache(auto_confirm = False):
    """
    check all existing NFS mounts, and update the read-ahead cache.
    add the udev rule to auto-apply the read-ahead cache
    """
    out, err = run_command("ls /etc/udev/rules.d/99-nfs.rules")
    if out and "/etc/udev/rules.d/99-nfs.rules" in out:
        print("udev rule to apply read-ahead cache already exists, skipping")
        return
    
    if not auto_confirm:
        key_press = input(f"This script will now fix the read-ahead cache for NFS mounts,\n\twhich applies the recommended settings to improve sequential read performance.\n\tContinue? (y/N) ")
        if key_press.lower() != "y":
            print("User did not specify (y), so the operation was canceled")
            return
    
    _, err = run_command(r"""echo 'SUBSYSTEM=="bdi", ACTION=="add", PROGRAM="/bin/awk -v bdi=$kernel '\''BEGIN{ret=1} {if ($$4 == bdi) {ret=0}} END{exit ret}'\'' /proc/fs/nfsfs/volumes", ATTR{read_ahead_kb}="16384"' | sudo sh -c 'cat > /etc/udev/rules.d/95-nfs-readahead.rules'""")
    if err:
        print(f"ERROR: failure creating udev rule: {err}")
        return
    
    _, err = run_command("sudo udevadm control --reload-rules && sudo udevadm trigger --verbose --action add --subsystem-match nvme && sudo udevadm trigger --verbose --action add")
    if err:
        print(f"ERROR: could not reload udev rules: {err}")
        return
    
    _, err = run_command("""echo '[nfsrahead]
    nfs=16384
    nfs4=16384
    default=128' | sudo sh -c 'cat >> /etc/nfs.conf'""")
    if err:
        print(f"ERROR: could not reload udev rules: {err}")
        return
    
    print("Updated readahead cache settings successfully.")
def optimize_network_interface(auto_confirm = False):
    """
    optimizes the VM's network interface settings
    for high shared disk performance.
    add a systemctl service to auto-apply the following settings on restart:
    - MTU of 9000,
    - ring buffer set to 8192
    """
    if not auto_confirm:
        key_press = input(f"This script will now optimize the VM's network interface,\n\twhich applies the recommended settings to improve shared disk network performance.\n\tThis will be applied via creating a systemd service under /etc/systemd/system/network-config-nfs.service.\n\tContinue? (y/N) ")
        if key_press.lower() != "y":
            print("User did not specify (y), so the operation was canceled")
            return

    _, err = run_command(
        r"""
        sudo sh -c "echo \"#!/bin/bash\" > /usr/local/bin/network-config-nfs.sh"
        """
    )
    if err:
        print(f"ERROR: could not apply MTU for network-config-nfs.sh: {err}")
        return

    _, err = run_command(
        r"""
        sudo sh -c "echo \"ip -o link show | awk -F': ' '/ens/{print $\"2\"}' | xargs -r -I{} sudo ip link set dev {} mtu 9000\" >> /usr/local/bin/network-config-nfs.sh"
        """
    )
    if err:
        print(f"ERROR: could not apply MTU for network-config-nfs.sh: {err}")
        return

    _, err = run_command(
        r"""
        sudo sh -c "echo \"ip -o link show | awk -F': ' '/ens/{print $\"2\"}' | xargs -r -I{} bash -c 'sudo ethtool -G {} tx 8192 && sudo ethtool -G {} rx 8192'\" >> /usr/local/bin/network-config-nfs.sh"
        """
    )
    if err:
        print(f"ERROR: could not apply ring buffer for network-config-nfs.sh: {err}")
        return

    _, err = run_command("sudo chmod +x /usr/local/bin/network-config-nfs.sh")
    if err:
        print(f"ERROR: could not apply chmod for network-config-nfs.sh: {err}")
        return
    
    _, err = run_command(
        r"""
        sudo sh -c 'echo "[Unit]\nDescription=Network Configuration for NFS\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/network-config-nfs.sh\n\n[Install]\nWantedBy=multi-user.target" > /etc/systemd/system/network-config-nfs.service'
        """
    )
    if err:
        print(f"ERROR: could not apply systemd for network-config-nfs.sh: {err}")
        return
    
    _, err = run_command("sudo systemctl daemon-reload && sudo systemctl enable network-config-nfs.service && sudo systemctl start network-config-nfs.service")
    if err:
        print(f"ERROR: could not apply systemd for network-config-nfs.sh: {err}")
        return
    
    print("Optimized network interface settings successfully.")
def check_args_y():
    parser = argparse.ArgumentParser(description="A script that checks for a -y flag.")
    parser.add_argument('-y', action='store_true', help="A flag to confirm an action.")

    args = parser.parse_args()

    return args.y
def do_main():
    auto_confirm = check_args_y()
    success = install_VAST_NFS_driver(auto_confirm)
    
    if success:
        update_read_ahead_cache(auto_confirm)
        optimize_network_interface(auto_confirm)
    else:
        sys.exit(1)
if __name__ == "__main__":
    do_main()
