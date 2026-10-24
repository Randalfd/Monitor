#!/bin/bash

# Set interval
INTERVAL=10

# Get current time
CURRENT_TIME=$(date +%s)

# Read timer from user (in minutes)
echo "Introducir tiempo limite(minutos)"
read TIMER

# Convert to seconds properly
TIMER_IN_SECONDS=$((TIMER * 60))

# Get script directory for proper sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source DTOs
source "$SCRIPT_DIR/../dto/status_dto.sh"
source "$SCRIPT_DIR/../dto/table_dto.sh"

# Initialize arrays to store metrics
declare -a cpu_values mem_values swap_values disk_values

# Function to capture CPU usage (user + system)
get_cpu_usage() {
  top -bn1 | grep 'Cpu(s)' | awk '{print int($2 + $4)}'
}

# Function to capture memory usage
get_mem_usage() {
  free | grep Mem | awk '{print int($3/$2 * 100.0)}'
}

# Function to capture swap usage
get_swap_usage() {
  free | grep Swap | awk '{if ($2 > 0) print int($3/$2 * 100.0); else print 0}'
}

# Function to capture disk usage
get_disk_usage() {
  df / | grep / | awk '{print int($5)}'
}

# Function to log metrics and store in arrays
log_metrics() {
  local timestamp="$1"
  local cpu
  local mem
  local swap
  local disk

  cpu=$(get_cpu_usage)
  mem=$(get_mem_usage)
  swap=$(get_swap_usage)
  disk=$(get_disk_usage)

  # Store values in arrays
  cpu_values+=("$cpu")
  mem_values+=("$mem")
  swap_values+=("$swap")
  disk_values+=("$disk")

  # Create status DTO with measured values
  create_status_dto "$timestamp" "$cpu" "$mem" "$swap" "$disk"

  # Print metrics
  printf 'CPU: %s%% | Mem: %s%% | Swap: %s%% | Disk: %s%%\n' \
    "${status_dto[cpu]}" \
    "${status_dto[ram]}" \
    "${status_dto[swap]}" \
    "${status_dto[disk]}"
}

# Main monitoring loop
END_TIME=$((CURRENT_TIME + TIMER_IN_SECONDS))

while [[ $CURRENT_TIME -lt $END_TIME ]]; do
  CURRENT_TIME=$(date +%s)

  # Only log if we haven't exceeded the timer
  if [[ $CURRENT_TIME -lt $END_TIME ]]; then
    log_metrics "$(date +%s)"
    sleep "$INTERVAL"
  fi
done

# Calculate statistics using simple loops (avoiding eval)
# CPU stats
cpu_count=${#cpu_values[@]}
if [[ $cpu_count -gt 0 ]]; then
  cpu_min=${cpu_values[0]}
  cpu_max=$cpu_min
  cpu_sum=0
  for val in "${cpu_values[@]}"; do
    if ((val < cpu_min)); then cpu_min=$val; fi
    if ((val > cpu_max)); then cpu_max=$val; fi
    cpu_sum=$((cpu_sum + val))
  done
  cpu_avg=$((cpu_sum / cpu_count))
else
  cpu_min=0
  cpu_max=0
  cpu_avg=0
fi

# MEM stats
mem_count=${#mem_values[@]}
if [[ $mem_count -gt 0 ]]; then
  mem_min=${mem_values[0]}
  mem_max=$mem_min
  mem_sum=0
  for val in "${mem_values[@]}"; do
    if ((val < mem_min)); then mem_min=$val; fi
    if ((val > mem_max)); then mem_max=$val; fi
    mem_sum=$((mem_sum + val))
  done
  mem_avg=$((mem_sum / mem_count))
else
  mem_min=0
  mem_max=0
  mem_avg=0
fi

# SWAP stats
swap_count=${#swap_values[@]}
if [[ $swap_count -gt 0 ]]; then
  swap_min=${swap_values[0]}
  swap_max=$swap_min
  swap_sum=0
  for val in "${swap_values[@]}"; do
    if ((val < swap_min)); then swap_min=$val; fi
    if ((val > swap_max)); then swap_max=$val; fi
    swap_sum=$((swap_sum + val))
  done
  swap_avg=$((swap_sum / swap_count))
else
  swap_min=0
  swap_max=0
  swap_avg=0
fi

# Disk stats
disk_count=${#disk_values[@]}
if [[ $disk_count -gt 0 ]]; then
  disk_last=${disk_values[$((disk_count - 1))]}
  disk_min=$disk_last
  disk_max=$disk_last
else
  disk_last=0
  disk_min=0
  disk_max=0
fi

# Create table DTO with all statistics
create_table_dto "$(date +%s)" \
  "$cpu_min" "$mem_min" "$swap_min" "$disk_min" "$disk_last" \
  "$cpu_avg" "$mem_avg" "$swap_avg" \
  "$cpu_max" "$mem_max" "$swap_max" "$disk_max"

# Display final statistics using table DTO
echo "=== Statistics ==="
echo "CPU - Min: ${table_dto[minCpu]}% | Max: ${table_dto[maxCpu]}% | Avg: ${table_dto[avgCpu]}%"
echo "Mem - Min: ${table_dto[minRam]}% | Max: ${table_dto[maxRam]}% | Avg: ${table_dto[avgRam]}%"
echo "Swap - Min: ${table_dto[minSwap]}% | Max: ${table_dto[maxSwap]}% | Avg: ${table_dto[avgSwap]}%"
echo "Disk - Last: ${table_dto[lastDisk]}%"

echo "Monitoring completed. Total time elapsed: $(($(date +%s) - CURRENT_TIME)) seconds"
