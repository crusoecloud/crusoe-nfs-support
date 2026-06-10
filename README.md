# crusoe-nfs-support

Scripts and driver packages from the Crusoe Cloud team for using [Shared Disks](https://docs.crusoecloud.com/storage/disks/managing-shared-disks) over NFS.

## Repository layout

| Directory | Contents |
|---|---|
| [`setup/`](setup/) | NFS driver installer for VMs that mount Shared Disks |
| [`support/`](support/) | Diagnostic and verification scripts for troubleshooting NFS clients |
| [`debs/`](debs/) | VAST NFS dkms driver packages (downloaded automatically by the setup script) |
| [`archive/`](archive/) | Legacy migration scripts |

## Quick start

> [!IMPORTANT]
> Installing the Crusoe NFS drivers can disrupt existing NFS mounts on your VM. If applicable, please stop any active workflows before proceeding.

On the VM:

```
wget -O crusoe_shared_disks_nfs_setup.py https://github.com/crusoecloud/crusoe-nfs-support/raw/refs/heads/main/setup/crusoe_shared_disks_nfs_setup.py
python3 crusoe_shared_disks_nfs_setup.py --apply-read-ahead-cache --apply-network-optimizations
```

To install across multiple VMs at once, see [`setup/README.md`](setup/README.md).

For full documentation, see [Setting up the VAST NFS driver](https://docs.crusoecloud.com/storage/disks/setup-nfs-driver) on the Crusoe Cloud docs site.
