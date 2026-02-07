#!/usr/bin/env bash

# --- Configuration --- #
remote_host=""
remote_ip=""
remote_mac=""
subnet_broadcast=""
remote_username=""
ssh_pubkey=""
ssh_port=""
remote_target="$remote_username@$remote_host"
remote_dev=""
mapper_name=""
mount_path=""
keyfile=""

# --- Configuration --- #

# Function to handle the wake up
wakeup() {
    if wol -i "$subnet_broadcast" "$remote_mac"; then
	echo "Waiting for Host: $remote_host ($remote_ip) to wake up."
else
	echo "Failed to send wake packet. Check if 'wol' is installed."
	return 1
	fi

}

# Function to check if remote host is online
ping_host() {
	until ping -c 1 -w 1 "$remote_ip" &> /dev/null; do
	printf "."
	sleep 1 
done

if [[ $? -eq 0 ]]; then
    echo -e "\nSuccess: $remote_host is now online."
else
    echo "Host failed to innitialize."
    return 1
fi
}

# Function to ssh-in remote host
ssh_in() {
    echo "Connecting to $remote_host ($remote_ip) over SSH"
    ssh -i "$ssh_pubkey" "$remote_host"@"$remote_username" -p "$ssh_port" -t
    if [[ $? -eq 0 ]]; then
        echo "Success: dropping into shell."
    else
        echo "Failure: Connection to host was unsuccessfull. Check your settings and try again."
        return 1
    fi
}

# Function to check remote sudo permissions
check_remote_sudo() {
    echo "Checking sudo permissions on $remote_host..."
    if ssh -t -p "$ssh_port" "$remote_username@$remote_host" "sudo -v"; then
        echo "Success: $remote_username has sudo permissions."
        return 0
    else
        echo "Failure: Remote sudo check failed or password incorrect."
        return 1
    fi
}

# Function to decrypt drive
decrypt() {
	echo "Decrypting drive: $mapper_name"
	cat "$keyfile" | ssh -p "$ssh_port" "$remote_target" "sudo cryptsetup luksOpen $remote_dev $mapper_name --key-file=-"
    if [[ $? -eq 0 ]]; then
        echo "Success: $mapper_name mounted successfully."
        return 0
    else
        echo "Failed to decripy $mapper_name. Check your Keyfile or mount point are correct."
        return 1
    fi
}

# Function to mount drive
mount_drive() {
    echo "Attempting to mount device."
    if ssh -t -p "$ssh_port" $remote_target "sudo mount /dev/mapper/$mapper_name $mount_path"; then
    echo "Success: Drive $mapper_name mounted at $mount_path."
    return 0
else
    echo "Failure: Could not mount drive. Check the device or mount point and try again."
    return 1
    fi
}

# Function to handle rsync flags
rsync_menu() {
    local PS3="Please select yout rsync configuration: "
    local options=("LAN Fast Mirror (Default)" "WAN Slow Mirror" "Paranoid Mirror" "Test Run")

    select opt in "${options[@]}"
    do
    case $opt in
        "LAN Fast Mirror (Default)")
            # Local LAN fast mirror – most common server → NAS / second server
            flags="-aHXX --numeric-ids --delete --delete-excluded --inplace --info=progress2 --stats --log-file=./rsync-backup.log"
            break 
            ;;
        "WAN Slow Mirror")
            #Important backup over slower / unstable link
        flags="-aHXX --numeric-ids --inplace --partial --partial-dir=.rsync-partial --timeout=600 --info=progress2 --stats --log-file=./rsync-backup.log"
        break
        ;;
    "Paranoid Mirror")
        # Very paranoid versioned-like mirror (using --link-dest trick separately)
        flags="aHXX --numeric-ids --delete --delete-after --link-dest=../backup-previous --info=progress2 --log-file=./rsync-backup.log" 
        break
        ;;
        "Test Run")
            # Dry Run
            flags="-ah --delete --dry-run --itemize-changes --verbose --stats"
            break
            ;;
        *) echo "Invalid option $REPLY";;
    esac
done
}

# Function to confirm before running
confirm_and_run() {
    local flags=$1
    
    echo "--- FINAL CONFIRMATION ---"
    echo "Source:      $local_src"
    echo "Destination: $remote_dest"
    echo "Flags:       $flags"
    echo "--------------------------"
    
    read -r -p "Are you sure you want to proceed? (y/N): " confirm
    
    case "$confirm" in
        [yY][eE][sS]|[yY]) 
            run_sync "$flags"
            ;;
        *)
            echo "Sync cancelled by user."
            return 1
            ;;
    esac
}

# Function to start rsync
run_rsync() {
    local flags=$1
    local ssh_sync="ssh -p $ssh_port $local_src $remote_target:$mount_path/$remote_dest"
    
    echo "Starting Syncing process..."
    rsync $flags -e $ssh_sync

    if [[ $? -eq 0 ]]; then
        echo "Success: Sync is now completed."
        return 0
    else
        echo "Failed: Unable to complete sync."
        return 1
    fi
            }


# Function to handle cleanup
cleanup() {
	echo -e "\nUnmounting $mapper_name ($remote_dev) at $mount_path."
    ssh -p $ssh_port $remote_target "sudo umount $mount_path; sudo cryptsetup luksClose $mapper_name"
}


### ------ Stage 0: Set up the variables ------- ###
required_fields=("remote_host" "remote_ip" "remote_mac" "subnet_broadcast" "remote_username" "ssh_pubkey" "ssh_port" "remote_dev" "mapper_name" "mount_path" "keyfile" "local_src" "remote_dev")

for field in "${required_fields[@]}"; do
    while [[ -z "${!field}" ]]; do
        read -r -p "Required field $field is empty. Please choose a value: " "$field"
        
        if [[ -z "${!field}" ]]; then
            echo "Error: $field cannot be empty."
            fi
        done
    done

###------ Stage 1: Setting the stage up ------###

# Wake up the Host	
if ! wakeup; then
    echo "Failure: Unable to wake up host."
    exit 1
fi
# Check if the host is online
if ! ping_host; then
    echo "Failure: Host seems to be offile."
exit 1
fi

# check SSH connection
if ssh_in &>/dev/null; then
    echo "Success: Connection to $remote_target is possible."
else
    echo "Failure: Unable to SSH into host. Check your settings and try again"
    exit 1
fi

# Check remote user sudo permissions
if ! check_remote_sudo "backup-server" "admin"; then
    echo "Failure: Cannot proceed without remote sudo privileges."
    exit 1
fi


# Check if keyfile exists
if [[ ! -f "$keyfile" ]]; then
    echo "Error: Local keyfile '$keyfile' not found."
    exit 1
fi

# Decript the device
if ! decrypt; then
	echo "Failure: Unable to decrypt device."
		exit 1
fi

# Mount the drive
if ! mount_drive; then
    echo "Failure: Mount was unsuccessfull."
    exit 1
fi


### ------ Stage 2: Syncing directories ------ ###


# Setup Rsync source, destination, and flags. Will keep running until you choose not to anymore.

while true; do
    echo -e "\n--- Transfer Configuration ---"
    read -r -p "Please select a local source to backup: " local_src
    read -r -p "Please select the remote destination: " remote_dest
    
    rsync_menu
    confirm_and_run
    echo -e "\n --- Starting Syncing ---"
    run_rsync

    if [[ $? -ne 0 ]]; then
        echo "Failure: Unable to complete Sync."
        break
    fi
    
    read -r -p "Do you wish to sync another directory? (y/N)" keep_syncing
    case "$keep_syncing" in
        [Yy][eE][sS]) true;;
        [nN][oO]) echo "Exiting Syncing..." break;;
    esac
done

### ------ Stage 3: Unmount and Close ------ ###

# Cleanup 
cleanup

if [[ $? -eq 0 ]]; then
    echo "Success: Remote drive secured and session closed."
    exit 0
else
    echo "Warning: Manual check required. Drive may still be open."
    exit 1
fi


