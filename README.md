# Tempest Cleanup Script

A Bash script to clean up leftover OpenStack resources created by Tempest tests.

## Overview

`tempest_cleanup.sh` scans your OpenStack project for resources whose names contain `tempest` and deletes them in dependency-safe order. It logs all actions to a timestamped log file and prints a summary of remaining resources at the end.

## Features

- **Retry logic**: Each deletion is attempted up to 3 times with verification.
- **Dependency-aware ordering**: Deletes child resources (e.g., LB members, ports, subnet) before parents (e.g., LB, router, network).
- **Load balancer handling**: Cleans listeners, pools, members, and health monitors, and waits for stable provisioning state before deletion.
- **Project-scoped cleanup**: Removes all resources inside `tempest*` projects before deleting the projects themselves.
- **Safety check for users**: Skips deleting a user if it still has role assignments.
- **Summary report**: Prints counts of remaining VMs, vCPUs, RAM, volumes, networks, ports, routers, etc.

## Requirements

- `bash` (v4+)
- OpenStack CLI (`openstack`) configured with sufficient privileges to list and delete resources.
- Permissions to delete servers, volumes, snapshots, networks, subnets, routers, ports, floating IPs, security groups, flavors, images, keypairs, load balancers, projects, and users.

## Usage

```bash
chmod +x tempest_cleanup.sh
./tempest_cleanup.sh
```

No arguments are required. The script uses your current OpenStack credentials (from `openrc`, environment variables, or `clouds.yaml`).

## Logging

All output is written to both stdout and a log file:

```
tempest_cleanup_YYYYMMDD_HHMMSS.log
```

Each entry is prefixed with a timestamp.

## Cleanup Order

1. Servers
2. Load balancers (listeners → pools → members/health monitors)
3. Floating IPs (only those attached to `tempest` networks)
4. Ports
5. Routers
6. Subnets
7. Networks
8. Security groups (with their rules)
9. Volume snapshots
10. Volumes
11. Volume types
12. Flavors
13. Images
14. Keypairs
15. Projects (excluding `z-tempest*`)
16. Users (skipped if they still have role assignments)

## Notes & Caveats

- The script uses `set +e`; failures are logged but do not abort the run.
- Only resources whose **names contain `tempest`** are targeted.
- Floating IPs are only deleted when their associated port's network name contains `tempest`.
- Project cleanup explicitly excludes projects matching `z-tempest` (typically reserved/system projects).
- The final summary reflects **remaining** resources in the current project after cleanup.
- Some resources (e.g., flavors, images, volume types) may be shared; ensure you have a backup or that these are truly test artifacts before running.

## Example Output (summary)

```
 Resource                            | Count / Value
-------------------------------------+-----------------
 VMs (servers)                       | 0
 Total vCPUs (servers)               | 0
 Total RAM (MB, servers)             | 0
 Volumes                             | 0
 Total volume size (GB)              | 0
 Volume snapshots                    | 0
 Floating IPs                        | 0
 Security groups                     | 1
 Security group rules                | 4
 Networks                            | 0
 Ports                               | 0
 Routers                             | 0
```

## Disclaimer

This script performs **destructive** operations. Review the resource list carefully and run it only in test environments or against accounts where Tempest-generated resources are safe to remove.