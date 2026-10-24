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

# Function to capture CPU usage
get_cpu_usage() {
  # Get CPU idle and use 100 - idle
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

# Function to log metrics and create status DTO
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

echo "Monitoring completed. Total time elapsed: $(($(date +%s) - CURRENT_TIME)) seconds"
