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

3. Create a file, named hosts.txt, that includes the IP addresses, line-by-line, of the VMs to apply this script to. For example, it may look something like this:

```
touch hosts.txt
echo "ubuntu@1.2.3.4" >> hosts.txt
echo "ubuntu@1.2.3.5" >> hosts.txt
```

4. Use pscp and pssh to apply the script to multiple files at once. Note that the setup script can take a long time (more than a few minutes).

```
pscp -h hosts.txt crusoe_shared_disks_virtiofs_to_nfs.py /home/ubuntu/crusoe_shared_disks_virtiofs_to_nfs.py
pssh -t 0 -h hosts.txt "export DEBIAN_FRONTEND=noninteractive && python3 /home/ubuntu/crusoe_shared_disks_virtiofs_to_nfs.py -y"
```