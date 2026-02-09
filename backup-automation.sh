#!/usr/bin/env bash

set -euo pipefail

# Constants and configurable settings
MAX_PING_ATTEMPTS=180
SSH_CONNECT_TIMEOUT=10
SSH_OPTIONS_BASE="-o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=yes"
LOG_TIMESTAMP_FORMAT="%Y%m%d-%H%M%S"
ALLOWED_CHARS_PATTERN="[^a-zA-Z0-9_./-]"

### ------ Configuration ------ ###
remote_host=""
remote_ip=""
remote_mac=""
subnet_broadcast=""
remote_username=""
ssh_privkey=""
ssh_port=""
remote_dev=""
mapper_name=""
mount_path=""
keyfile=""
remote_target="$remote_username@$remote_host"

### ------ Functions ------ ###

wakeup() {
    local host="$1" mac="$2" bcast="$3"
    echo "Sending wake-up packet to $host ($mac)..."
    if wol -i "$bcast" "$mac"; then
        echo "Wake packet sent. Waiting for host to come online..."
        sleep 5
        return 0
    else
        echo "Failed to send wake packet. Check if 'wol' is installed."
        return 1
    fi
}

ping_host() {
    local ip="$1" max="$2"
    echo "Pinging $ip (max ${max}s)..."
    local i
    for ((i=1; i<=max; i++)); do
        if ping -c 1 -w 1 "$ip" &>/dev/null; then
            echo -e "\nSuccess: Host is online after $i attempts."
            return 0
        fi
        printf "."
        sleep 1
    done
    echo -e "\nFailure: Host did not respond within ${max} seconds."
    return 1
}

build_ssh_cmd() {
    local port="$1" key="$2" opts="$3"
    local cmd="ssh $opts -p $port"
    [[ -n "$key" ]] && cmd="$cmd -i $key"
    echo "$cmd"
}

check_remote_sudo() {
    local ssh_cmd; ssh_cmd=$(build_ssh_cmd "$1" "$2" "$3")
    local target="$4"

    echo "Checking sudo permissions on remote host..."
    if $ssh_cmd "$target" "sudo -v"; then
        echo "Success: User has sudo permissions."
        return 0
    else
        echo "Failure: sudo check failed."
        return 1
    fi
}

check_mapper_status() {
    local ssh_cmd; ssh_cmd=$(build_ssh_cmd "$1" "$2" "$3")
    local target="$4" mapper="$5"

    if $ssh_cmd "$target" "[ -b /dev/mapper/$mapper ]"; then
        echo "Warning: Mapper '$mapper' is already open."
        return 1
    fi
    return 0
}

check_mount_path() {
    local ssh_cmd; ssh_cmd=$(build_ssh_cmd "$1" "$2" "$3")
    local target="$4" mpath="$5"

    if $ssh_cmd "$target" "[ -d $mpath ]"; then
        return 0
    else
        echo "Error: Mount path '$mpath' does not exist remotely."
        return 1
    fi
}

decrypt() {
    local ssh_cmd; ssh_cmd=$(build_ssh_cmd "$1" "$2" "$3")
    local target="$4" dev="$5" mapper="$6" kf="$7"

    echo "Decrypting drive: $mapper"
    if $ssh_cmd "$target" "sudo cryptsetup luksOpen $dev $mapper --key-file=-" < "$kf"; then
        echo "Success: '$mapper' opened."
        return 0
    else
        echo "Failed to open LUKS device."
        return 1
    fi
}

mount_drive() {
    local ssh_cmd; ssh_cmd=$(build_ssh_cmd "$1" "$2" "$3")
    local target="$4" mapper="$5" mpath="$6"

    echo "Mounting /dev/mapper/$mapper → $mpath"
    if $ssh_cmd -t "$target" "sudo mount /dev/mapper/$mapper $mpath"; then
        echo "Success: Mounted."
        return 0
    else
        echo "Mount failed."
        return 1
    fi
}

sanitize_path() {
    local p="$1"
    p="${p#/}"
    p="${p%/}"
    p="${p//\/\///}"
    while [[ $p == *"/../"* ]]; do
        p="${p/\/..\///}"
    done
    p="${p//$ALLOWED_CHARS_PATTERN/}"
    echo "$p"
}

rsync_menu() {
    local PS3="Select rsync profile: "
    local options=("LAN Fast Mirror (Default)" "WAN Slow Mirror" "Paranoid Mirror" "Test Run" "Quit")
    local flags=

    while true; do
        select opt in "${options[@]}"; do
            case $opt in
                "LAN Fast Mirror (Default)")
                    flags="-aHXX --numeric-ids --delete --delete-excluded --inplace "
                    flags+="--info=progress2 --stats --log-file=./rsync-backup-$(date +"$LOG_TIMESTAMP_FORMAT").log"
                    return 0
                    ;;
                "WAN Slow Mirror")
                    flags="-aHXX --numeric-ids --inplace --partial --partial-dir=.rsync-partial "
                    flags+="--timeout=600 --info=progress2 --stats --log-file=./rsync-backup-$(date +"$LOG_TIMESTAMP_FORMAT").log"
                    return 0
                    ;;
                "Paranoid Mirror")
                    flags="-aHXX --numeric-ids --delete --delete-after --info=progress2 "
                    flags+="--log-file=./rsync-backup-$(date +"$LOG_TIMESTAMP_FORMAT").log"
                    return 0
                    ;;
                "Test Run")
                    flags="-ah --delete --dry-run --itemize-changes --verbose --stats"
                    return 0
                    ;;
                "Quit")
                    return 1
                    ;;
                *) echo "Invalid choice $REPLY";;
            esac
        done
    done
}

confirm_and_run() {
    local flags="$1" src="$2" dest="$3" port="$4" key="$5" target="$6" mpath="$7"

    cat <<EOF
--- FINAL CONFIRMATION ---
Source:      $src
Destination: $dest
Flags:       $flags
--------------------------
EOF

    read -r -p "Proceed? (y/N): " confirm
    case "$confirm" in
        [yY]*) run_rsync "$flags" "$src" "$dest" "$port" "$key" "$target" "$mpath" ;;
        *) echo "Sync cancelled."; return 1 ;;
    esac
}

run_rsync() {
    local flags="$1" src="$2" rdest="$3" port="$4" key="$5" target="$6" mpath="$7"
    local ssh_rsync="ssh -p $port"
    [[ -n "$key" ]] && ssh_rsync="$ssh_rsync -i $key"

    echo "Starting rsync..."
    if rsync $flags -e "$ssh_rsync" "$src" "$target:$mpath/$rdest"; then
        echo "Sync completed successfully."
        return 0
    else
        echo "rsync failed."
        return 1
    fi
}

cleanup() {
    local ssh_cmd; ssh_cmd=$(build_ssh_cmd "$1" "$2" "$3")
    local target="$4" mpath="$5" mapper="$6" dev="$7"

    echo -e "\nCleanup:"
    echo "  Unmounting $mpath..."
    $ssh_cmd "$target" "sudo umount $mpath" &>/dev/null &&
        echo "  Unmounted." || echo "  Unmount failed (maybe not mounted)"

    echo "  Closing LUKS device $mapper..."
    $ssh_cmd "$target" "sudo cryptsetup luksClose $mapper" &>/dev/null &&
        echo "  Closed." && return 0 ||
        echo "  luksClose failed (maybe not open)" && return 1
}

### ------ Main logic ------ ###

# Parse flags
dry_run=false
verbose=false
use_agent=false

while getopts ":dva" opt; do
    case $opt in
        d) dry_run=true ;;
        v) verbose=true ;;
        a) use_agent=true ;;
        \?) echo "Usage: $0 [-d dry-run] [-v verbose] [-a ssh-agent mode]"; exit 1 ;;
    esac
done
shift $((OPTIND-1))

[[ $verbose == true ]] && set -x

# If using agent don't pass private key file
[[ $use_agent == true ]] && ssh_privkey=""

# ── Stage 0: Configuration & validation ──

required_fields=(remote_host remote_ip remote_mac subnet_broadcast remote_username ssh_port mapper_name mount_path keyfile remote_dev)

for field in "${required_fields[@]}"; do
    while [[ -z "${!field}" ]]; do
        read -e -r -p "$field is empty. Enter value: " "$field"
        [[ -z "${!field}" ]] && echo "Error: cannot be empty."
    done
done

# Tilde expansion
ssh_privkey="${ssh_privkey/#\~/$HOME}"
keyfile="${keyfile/#\~/$HOME}"

# Basic validation
[[ $use_agent == false && ! -f "$ssh_privkey" ]] && { echo "SSH key not found: $ssh_privkey"; exit 1; }
[[ ! "$ssh_port" =~ ^[0-9]+$ ]] && { echo "Invalid SSH port"; exit 1; }
[[ ! -f "$keyfile" ]] && { echo "Keyfile not found: $keyfile"; exit 1; }

### ------ Stage 1: Wake-up, Connect, Decrypt and Mount ------ ###

wakeup "$remote_host" "$remote_mac" "$subnet_broadcast" || { echo "Wake failed"; exit 1; }
ping_host "$remote_ip" "$MAX_PING_ATTEMPTS" || { echo "Host never came online"; exit 1; }

# Test basic SSH
ssh_test=$(build_ssh_cmd "$ssh_port" "$ssh_privkey" "$SSH_OPTIONS_BASE")
$ssh_test "$remote_target" "exit 0" &>/dev/null ||
    { echo "Cannot connect via SSH"; exit 1; }
echo "SSH connection OK."

check_remote_sudo "$ssh_port" "$ssh_privkey" "$SSH_OPTIONS_BASE" "$remote_target" ||
    { echo "No sudo permission"; exit 1; }

check_mount_path "$ssh_port" "$ssh_privkey" "$SSH_OPTIONS_BASE" "$remote_target" "$mount_path" ||
    exit 1

check_mapper_status "$ssh_port" "$ssh_privkey" "$SSH_OPTIONS_BASE" "$remote_target" "$mapper_name" ||
    { echo "Mapper already open → aborting"; exit 1; }

decrypt "$ssh_port" "$ssh_privkey" "$SSH_OPTIONS_BASE" "$remote_target" "$remote_dev" "$mapper_name" "$keyfile" ||
    { echo "Decryption failed"; exit 1; }

# Set trap
trap 'ret=$?; cleanup "$ssh_port" "$ssh_privkey" "$SSH_OPTIONS_BASE" "$remote_target" "$mount_path" "$mapper_name" "$remote_dev"; exit $ret' EXIT INT TERM

mount_drive "$ssh_port" "$ssh_privkey" "$SSH_OPTIONS_BASE" "$remote_target" "$mapper_name" "$mount_path" ||
    { echo "Mount failed"; exit 1; }

### ------ Stage 2: Rsync loop ------ ###

if [[ $dry_run == true ]]; then
    echo "Dry-run mode active."
    flags="-ah --delete --dry-run --itemize-changes --verbose --stats"
else
    rsync_menu || { echo "Aborted from menu."; exit 0; }
fi

while true; do
    echo -e "\n--- Transfer setup ---"

    while true; do
        read -e -r -p "Local source (or 'q' to quit): " local_src
        [[ $local_src == q ]] && { echo "Exiting."; break 2; }
        local_src=$(sanitize_path "$local_src")
        [[ -e $local_src ]] && break
        echo "Path does not exist."
    done

    read -e -r -p "Remote destination (or 'q' to quit): " remote_dest
    [[ $remote_dest == q ]] && { echo "Exiting."; break; }
    remote_dest=$(sanitize_path "$remote_dest")

    [[ $dry_run == false ]] && rsync_menu || true

    confirm_and_run "$flags" "$local_src" "$remote_dest" "$ssh_port" "$ssh_privkey" "$remote_target" "$mount_path" ||
        { echo "Sync failed or cancelled."; break; }

    read -r -p "Sync another directory? (y/N/q): " cont
    case "$cont" in
        [yY]*) continue ;;
        [qQ]*) break ;;
        *) break ;;
    esac
done

# Explicit cleanup call (also handled by the trap)
if cleanup "$ssh_port" "$ssh_privkey" "$SSH_OPTIONS_BASE" "$remote_target" "$mount_path" "$mapper_name" "$remote_dev"; then
    echo "Cleanup successful. Session closed."
    exit 0
else
    echo "Cleanup incomplete — manual check recommended."
    exit 1
fi
