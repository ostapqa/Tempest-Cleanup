#!/bin/bash

LOG_FILE="tempest_cleanup_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

resource_exists() {
    local resource_type="$1"
    local resource_id="$2"
    log "Checking if $resource_type $resource_id exists..."
    case "$resource_type" in
        server) openstack server show "$resource_id" &>/dev/null ;;
        port) openstack port show "$resource_id" &>/dev/null ;;
        subnet) openstack subnet show "$resource_id" &>/dev/null ;;
        router) openstack router show "$resource_id" &>/dev/null ;;
        security_group) openstack security group show "$resource_id" &>/dev/null ;;
        network) openstack network show "$resource_id" &>/dev/null ;;
        volume) openstack volume show "$resource_id" &>/dev/null ;;
        volume_type) openstack volume type show "$resource_id" &>/dev/null ;;
        flavor) openstack flavor show "$resource_id" &>/dev/null ;;
        image) openstack image show "$resource_id" &>/dev/null ;;
        keypair) openstack keypair show "$resource_id" &>/dev/null ;;
        loadbalancer) openstack loadbalancer show "$resource_id" &>/dev/null ;;
        listener) openstack loadbalancer listener show "$resource_id" &>/dev/null ;;
        pool) openstack loadbalancer pool show "$resource_id" &>/dev/null ;;
        member) openstack loadbalancer member show "$3" "$resource_id" &>/dev/null ;;
        healthmonitor) openstack loadbalancer healthmonitor show "$resource_id" &>/dev/null ;;
        project) openstack project show "$resource_id" &>/dev/null ;;
        user) openstack user show "$resource_id" &>/dev/null ;;
        *) log "Unknown resource type: $resource_type"; return 1 ;;
    esac
    local status=$?
    log "$resource_type $resource_id exists: $status (0=exists, non-zero=does not exist)"
    return $status
}

print_cleanup_summary() {
    log "Cleanup summary (remaining resources in project)..."

    servers_raw=$(openstack server list --long -f value -c ID -c Name -c Flavor 2>/dev/null || true)
    vm_count=0
    total_vcpus=0
    total_ram_mb=0

    if [ -n "$servers_raw" ]; then
        while read -r sid sname sflavor; do
            [ -z "$sid" ] && continue
            vm_count=$((vm_count + 1))
            flavor_name=$(echo "$sflavor" | awk -F'(' '{print $1}' | xargs)
            if [ -n "$flavor_name" ]; then
                vcpus=$(openstack flavor show "$flavor_name" -f value -c vcpus 2>/dev/null || echo 0)
                ram=$(openstack flavor show "$flavor_name" -f value -c ram 2>/dev/null || echo 0)
                total_vcpus=$((total_vcpus + ${vcpus:-0}))
                total_ram_mb=$((total_ram_mb + ${ram:-0}))
            fi
        done <<< "$servers_raw"
    fi

    volumes_raw=$(openstack volume list -f value -c ID -c Name -c Size 2>/dev/null || true)
    volume_count=0
    total_vol_gb=0
    if [ -n "$volumes_raw" ]; then
        while read -r vid vname vsize; do
            [ -z "$vid" ] && continue
            volume_count=$((volume_count + 1))
            total_vol_gb=$((total_vol_gb + ${vsize:-0}))
        done <<< "$volumes_raw"
    fi

    snap_count=$(openstack volume snapshot list -f value -c ID 2>/dev/null | sed '/^$/d' | wc -l || echo 0)
    fip_count=$(openstack floating ip list -f value -c ID 2>/dev/null | sed '/^$/d' | wc -l || echo 0)
    sg_count=$(openstack security group list -f value -c ID 2>/dev/null | sed '/^$/d' | wc -l || echo 0)
    sgr_count=$(openstack security group rule list -f value -c ID 2>/dev/null | sed '/^$/d' | wc -l || echo 0)
    net_count=$(openstack network list -f value -c ID 2>/dev/null | sed '/^$/d' | wc -l || echo 0)
    port_count=$(openstack port list -f value -c ID 2>/dev/null | sed '/^$/d' | wc -l || echo 0)
    router_count=$(openstack router list -f value -c ID 2>/dev/null | sed '/^$/d' | wc -l || echo 0)

    {
        echo ""
        printf " %-35s | %-15s\n" "Resource" "Count / Value"
        echo "-------------------------------------+-----------------"
        printf " %-35s | %-15s\n" "VMs (servers)" "$vm_count"
        printf " %-35s | %-15s\n" "Total vCPUs (servers)" "$total_vcpus"
        printf " %-35s | %-15s\n" "Total RAM (MB, servers)" "$total_ram_mb"
        printf " %-35s | %-15s\n" "Volumes" "$volume_count"
        printf " %-35s | %-15s\n" "Total volume size (GB)" "$total_vol_gb"
        printf " %-35s | %-15s\n" "Volume snapshots" "$snap_count"
        printf " %-35s | %-15s\n" "Floating IPs" "$fip_count"
        printf " %-35s | %-15s\n" "Security groups" "$sg_count"
        printf " %-35s | %-15s\n" "Security group rules" "$sgr_count"
        printf " %-35s | %-15s\n" "Networks" "$net_count"
        printf " %-35s | %-15s\n" "Ports" "$port_count"
        printf " %-35s | %-15s\n" "Routers" "$router_count"
        echo ""
    } | tee -a "$LOG_FILE"
}

delete_resource() {
    local resource_type="$1"
    local resource_id="$2"
    local extra_arg="$3"
    local max_attempts=3
    local attempt=1

    set +e

    while [ $attempt -le $max_attempts ]; do
        log "Attempt $attempt to delete $resource_type $resource_id"
        if [ -n "$extra_arg" ]; then
            error_output=$(openstack "$resource_type" delete "$resource_id" "$extra_arg" 2>&1)
        else
            error_output=$(openstack "$resource_type" delete "$resource_id" 2>&1)
        fi
        local delete_status=$?
        if [ $delete_status -eq 0 ]; then
            sleep 2
            if ! resource_exists "$resource_type" "$resource_id" "$extra_arg"; then
                log "$resource_type $resource_id has been deleted"
                return 0
            else
                log "Warning: $resource_type $resource_id still exists after deletion attempt"
            fi
        else
            log "Failed to delete $resource_type $resource_id: $error_output"
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    log "Error: Failed to delete $resource_type $resource_id after $max_attempts attempts"
    return 1
}


cleanup_tempest() {
    log "Starting Tempest resource cleanup..."

    # 1. Delete servers
    log "Cleaning up servers..."
    servers=$(openstack server list --all -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for server in $servers; do
        delete_resource "server" "$server" || log "Continuing despite failure to delete server $server"
    done

    # 2. Delete load balancers
    log "Cleaning up load balancers..."
    loadbalancers=$(openstack loadbalancer list -f value -c id -c name 2>/dev/null | grep tempest | awk '{print $1}' || true)
    for lb in $loadbalancers; do
        log "Processing loadbalancer $lb..."

        listeners=$(openstack loadbalancer listener list --loadbalancer "$lb" -f value -c id 2>/dev/null || true)
        for listener in $listeners; do
            log "  Processing listener $listener..."

            pools=$(openstack loadbalancer pool list --listener "$listener" -f value -c id 2>/dev/null || true)
            for pool in $pools; do
                log "    Processing pool $pool..."

                members=$(openstack loadbalancer member list "$pool" -f value -c id 2>/dev/null || true)
                for member in $members; do
                    log "      Deleting member $member from pool $pool"
                    openstack loadbalancer member delete "$pool" "$member" 2>/dev/null || \
                        log "      Warning: Failed to delete member $member"
                done

                healthmonitors=$(openstack loadbalancer healthmonitor list --pool "$pool" -f value -c ID 2>/dev/null || true)
                for hm in $healthmonitors; do
                    log "      Deleting healthmonitor $hm from pool $pool"
                    openstack loadbalancer healthmonitor delete "$hm" 2>/dev/null || \
                        log "      Warning: Failed to delete healthmonitor $hm"
                done

                log "    Deleting pool $pool"
                openstack loadbalancer pool delete "$pool" 2>/dev/null || \
                    log "    Warning: Failed to delete pool $pool"
            done

            log "  Deleting listener $listener"
            openstack loadbalancer listener delete "$listener" 2>/dev/null || \
                log "  Warning: Failed to delete listener $listener"
        done

        log "  Waiting for loadbalancer $lb to reach stable state..."
        for i in {1..30}; do
            status=$(openstack loadbalancer show "$lb" -f value -c provisioning_status 2>/dev/null || true)
            if [ "$status" != "PENDING_UPDATE" ] && [ "$status" != "PENDING_DELETE" ] && [ "$status" != "PENDING_CREATE" ]; then
                log "  Loadbalancer $lb is in state: $status"
                break
            fi
            log "  Loadbalancer $lb is in $status, waiting..."
            sleep 2
        done

        log "  Deleting loadbalancer $lb"
        openstack loadbalancer delete "$lb" 2>/dev/null || \
            log "  Warning: Failed to delete loadbalancer $lb"
    done
    

    # 3. Delete floating IPs
    log "Cleaning up floating IPs..."
    fips=$(openstack floating ip list -f value -c ID 2>/dev/null || true)
    for fip in $fips; do
        port_id=$(openstack floating ip show "$fip" -f value -c port_id 2>/dev/null || true)
        if [ -n "$port_id" ]; then
            port_network=$(openstack port show "$port_id" -f value -c network_id 2>/dev/null || true)
            if [ -n "$port_network" ] && openstack network show "$port_network" -f value -c Name | grep -q tempest; then
                delete_resource "floating ip" "$fip" || log "Continuing despite failure to delete floating ip $fip"
            fi
        fi
    done

    # 4. Delete ports
    log "Cleaning up ports..."
    networks=$(openstack network list -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    ports=""
    for network in $networks; do
        ports="$ports $(openstack port list --network "$network" -f value -c ID 2>/dev/null || true)"
    done
    ports=$(echo "$ports" | tr ' ' '\n' | sort -u)
    for port in $ports; do
        router=$(openstack port show "$port" -f value -c device_id 2>/dev/null || true)
        if [ -n "$router" ] && openstack router show "$router" &>/dev/null; then
            log "Removing port $port from router $router"
            openstack router remove port "$router" "$port" >/dev/null 2>&1 || log "Warning: Failed to remove port $port from router $router"
        fi
        delete_resource "port" "$port" || log "Continuing despite failure to delete port $port"
    done

    # 5. Delete routers
    log "Cleaning up routers..."
    routers=$(openstack router list -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for router in $routers; do
        ports_of_router=$(openstack router show "$router" -f json | grep -oE '"port_id":\s*"[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}' 2>/dev/null || true)
        for port in $ports_of_router; do
            openstack router remove port "$router" "$port" >/dev/null 2>&1 || log "Warning: Failed to remove port $port from router $router"
        done
        delete_resource "router" "$router" || log "Continuing despite failure to delete router $router"
    done

    # 6. Delete subnets
    log "Cleaning up subnets..."
    subnets=$(openstack subnet list -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for subnet in $subnets; do
        delete_resource "subnet" "$subnet" || log "Continuing despite failure to delete subnet $subnet"
    done

    # 7. Delete networks
    log "Cleaning up networks..."
    networks=$(openstack network list -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for network in $networks; do
        delete_resource "network" "$network" || log "Continuing despite failure to delete network $network"
    done

    # 8. Delete security groups
    log "Cleaning up security groups..."
    security_groups=$(openstack security group list -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for sg in $security_groups; do
        sg_rules=$(openstack security group rule list "$sg" -f value -c ID 2>/dev/null || true)
        for rule in $sg_rules; do
            openstack security group rule delete "$rule" >/dev/null 2>&1 || log "Warning: Failed to delete security group rule $rule"
        done
        delete_resource "security group" "$sg" || log "Continuing despite failure to delete security group $sg"
    done

    # 9. Delete volume snapshots
    log "Cleaning up volume snapshots..."
    snapshots=$(openstack volume snapshot list --all -f value -c ID -c Name 2>/dev/null | grep tempest | awk '{print $1}' || true)
    for snap in $snapshots; do
        openstack volume snapshot delete "$snap" >/dev/null 2>&1 || log "Warning: Failed to delete volume snapshot $snap"
    done

    # 10. Delete volumes
    log "Cleaning up volumes..."
    volumes=$(openstack volume list --all -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for volume in $volumes; do
        delete_resource "volume" "$volume" || log "Continuing despite failure to delete volume $volume"
    done

    # 11. Delete volume types
    log "Cleaning up volume types..."
    volume_types=$(openstack volume type list -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for volume_type in $volume_types; do
        delete_resource "volume type" "$volume_type" || log "Continuing despite failure to delete volume type $volume_type"
    done

    # 12. Delete flavors
    log "Cleaning up flavors..."
    flavors=$(openstack flavor list --all -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for flavor in $flavors; do
        delete_resource "flavor" "$flavor" || log "Continuing despite failure to delete flavor $flavor"
    done

    # 13. Delete images
    log "Cleaning up images..."
    images=$(openstack image list --all -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for image in $images; do
        delete_resource "image" "$image" || log "Continuing despite failure to delete image $image"
    done

    # 14. Delete keypairs
    log "Cleaning up keypairs..."
    keypairs=$(openstack keypair list -f value -c Name | grep tempest 2>/dev/null || true)
    for keypair in $keypairs; do
        delete_resource "keypair" "$keypair" || log "Continuing despite failure to delete keypair $keypair"
    done

    # 15. Delete projects
    log "Cleaning up projects..."
    projects=$(openstack project list -f value -c ID -c Name | grep tempest | grep -v z-tempest | awk '{print $1}' 2>/dev/null || true)
    for project in $projects; do
        log "Ensuring all resources in project $project are deleted..."
        openstack server list --project "$project" -f value -c ID | while read -r server; do
            delete_resource "server" "$server" || log "Continuing despite failure to delete server $server in project $project"
        done
        openstack volume list --project "$project" -f value -c ID | while read -r volume; do
            delete_resource "volume" "$volume" || log "Continuing despite failure to delete volume $volume in project $project"
        done
        openstack network list --project "$project" -f value -c ID | while read -r network; do
            delete_resource "network" "$network" || log "Continuing despite failure to delete network $network in project $project"
        done
        delete_resource "project" "$project" || log "Continuing despite failure to delete project $project"
    done

    # 16. Delete users
    log "Cleaning up users..."
    users=$(openstack user list -f value -c ID -c Name | grep tempest | awk '{print $1}' 2>/dev/null || true)
    for user in $users; do
        role_assignments=$(openstack role assignment list --user "$user" -f value -c Project 2>/dev/null || true)
        if [ -n "$role_assignments" ]; then
            log "Warning: User $user has role assignments in projects: $role_assignments. Skipping deletion."
            continue
        fi
        delete_resource "user" "$user" || log "Continuing despite failure to delete user $user"
    done

}

set +e
cleanup_tempest
print_cleanup_summary