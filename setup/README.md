# Setup

`crusoe_shared_disks_nfs_setup.py` installs and activates the VAST NFS driver required to mount Crusoe Cloud Shared Disks. Optional flags:

- `--apply-read-ahead-cache` — increases the NFS read-ahead cache to 16MB (recommended).
- `--apply-network-optimizations` — applies MTU and ring-buffer optimizations (recommended).
- `-y` — skip confirmation prompts.

> [!IMPORTANT]
> Installing the Crusoe NFS drivers can disrupt existing NFS mounts on your VM. If applicable, please stop any active workflows before proceeding.

## Single VM

```
wget -O crusoe_shared_disks_nfs_setup.py https://github.com/crusoecloud/crusoe-nfs-support/raw/refs/heads/main/setup/crusoe_shared_disks_nfs_setup.py
python3 crusoe_shared_disks_nfs_setup.py --apply-read-ahead-cache --apply-network-optimizations
```

## Multiple VMs with pssh

1. Download the script locally (see above), then create a `hosts.txt` file listing the VMs to apply it to:

```
touch hosts.txt
echo "ubuntu@1.2.3.4" >> hosts.txt
echo "ubuntu@1.2.3.5" >> hosts.txt
```

2. Use `pscp` and `pssh` to run the script on all hosts. Note that the setup script can take a long time (more than a few minutes):

```
pscp -h hosts.txt crusoe_shared_disks_nfs_setup.py /home/ubuntu/crusoe_shared_disks_nfs_setup.py
pssh -t 0 -h hosts.txt "export DEBIAN_FRONTEND=noninteractive && python3 /home/ubuntu/crusoe_shared_disks_nfs_setup.py -y --apply-read-ahead-cache --apply-network-optimizations"
```

On Linux the commands are named `parallel-scp` / `parallel-ssh`.
