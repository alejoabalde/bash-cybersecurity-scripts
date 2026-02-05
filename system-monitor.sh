#!/usr/bin/env bash

# ---- CPU temperature: HIGHEST CORE TEMP ------------------------------
CPU_TEMP=$(sensors 2>/dev/null | grep "Core [0-9]:" | awk '{gsub(/[+.0]/,"",$3); print $3}' | sort -n | tail -1)

# ---- CPU load %: OVERALL AVERAGE --------------------------------------
CPU_USAGE=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print int(usage)}')

# ---- GPU temperature & load -------------------------------------------
GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
GPU_LOAD=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' %')

# ---- RAM: Used in GB (e.g., 4.5G) ------------------------------------
RAM_USED=$(free -h | awk '/Mem:/ {print $3}')

# ---- NVMe temperature --------------------------------------------------
NVME_TEMP=$(sensors 2>/dev/null | grep -i "Composite" | awk '{print $2}' | tr -d '+')

# ---- Network speed (1-second sample) ----------------------------------
INTERFACE="wlp60s0"

if [[ -f "/sys/class/net/$INTERFACE/statistics/rx_bytes" ]] && [[ -f "/sys/class/net/$INTERFACE/statistics/tx_bytes" ]]; then
    RX1=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes")
    TX1=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes")
    sleep 1
    RX2=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes")
    TX2=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes")
    DOWN_KB=$(( (RX2 - RX1) / 1024 ))
    UP_KB=$(( (TX2 - TX1) / 1024 ))
    if command -v bc >/dev/null 2>&1; then
        (( DOWN_KB >= 1024 )) && DOWN_STR=$(echo "scale=1; $DOWN_KB / 1024" | bc)M || DOWN_STR="${DOWN_KB}K"
        (( UP_KB >= 1024 )) && UP_STR=$(echo "scale=1; $UP_KB / 1024" | bc)M || UP_STR="${UP_KB}K"
    else
        DOWN_STR="${DOWN_KB}K"
        UP_STR="${UP_KB}K"
    fi
fi

# ---- FINAL OUTPUT ---------------------------------------
echo "\
 ${CPU_TEMP} ${CPU_USAGE}% | \
' ${GPU_TEMP}°C ${GPU_LOAD}% | \
  ${RAM_USED} | \
󰋊 ${NVME_TEMP} | \
↓${DOWN_STR} ↑${UP_STR}"
