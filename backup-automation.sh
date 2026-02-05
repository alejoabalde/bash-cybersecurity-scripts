#!/usr/bin/env bash

# --- Configuration --- #
host="Debian"
ip="192.168.1.114"
mac="d4:3d:7e:f9:4a:d2"

# Send the Wake-on-LAN packet
if wol -i "192.168.1.255" "$mac" &> /dev/null; then
	echo -e "Wake packet sent to $host ($ip).\nWaiting for host to be online."
	until ping -c 1 -w 1 "$ip" &> /dev/null; do
	printf "."
	sleep 1 
done

else
	echo "Failed to send wake packet. Check if 'wol' is installed."
	exit 1
fi

echo -e "\n$host is now online."

