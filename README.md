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
pscp -h hosts.txt install.py /home/ubuntu/crusoe_shared_disks_nfs_setup.py
pssh -t 0 -h hosts.txt "export DEBIAN_FRONTEND=noninteractive && python3 /home/ubuntu/crusoe_shared_disks_nfs_setup.py -y"
```
