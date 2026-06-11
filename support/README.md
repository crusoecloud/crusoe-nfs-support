# Support

Diagnostic scripts for troubleshooting NFS clients on Crusoe Cloud VMs.

- `nfs_client_support_bundle.sh` collects NFS client diagnostics (logs, kernel stats, network info, configuration) into a support bundle. Run on the affected VM.
- `nfs_report_generator.sh` renders the output of `nfs_client_support_bundle.sh` into an interactive HTML report.
- `crusoe_verify_nfs_mounts.sh` audits NFS mounts across hosts via SSH and tests read/write access on each mount.
