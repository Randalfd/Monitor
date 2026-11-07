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
source "$SCRIPT_DIR/../dto/alert_dto.sh"

# Fake admin email for alert mails
ADMIN_EMAIL="santiagokgutierrez@gmail.com"

# Initialize arrays to store metrics
declare -a cpu_values mem_values swap_values disk_values timestamp_values

# Log Function
LOG_FILE="$SCRIPT_DIR/../logs/monitor.log"

log_message() {
  local level="$1"
  local message="$2"
  local timestamp

  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  mkdir -p "$(dirname "$LOG_FILE")"

  echo "[$timestamp] [$level] $message" >>"$LOG_FILE"
}

# Alert flags
consecutive_cpu_alerts=0
disk_alert_pending=0

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

# Create and display alert via alert DTO
send_alert() {
  local problem="$1"

  create_alert_dto "$problem" "$(date +%s)"

  log_message "WARNING" "${alert_dto[problem]}"

  echo "Warning: ${alert_dto[problem]}"
  echo "Date: ${alert_dto[timestamp]}"
}

# Send alert mail to admin (real send attempt, fake recipient)
send_mail() {
  local problem="$1"
  echo "Subject: Alerta monitor - ${problem}
To: ${ADMIN_EMAIL}
From: monitor@example.com

${problem}" | timeout 10 sendmail -t
}

# List top 5 processes with highest RAM usage
get_top_ram_processes() {
  ps aux --sort=-%mem | awk 'NR > 1 { printf "%-10s %5s%% %s\n", $1, $4, $11 }' | head -5
}

# Generate HTML report
generate_html_report() {

  local TEMPLATE="$SCRIPT_DIR/../templates/report_template.html"
  local OUTPUT_DIR="$SCRIPT_DIR/../reports"

  mkdir -p "$OUTPUT_DIR"

  # User prompts
  read -r -p "Report title: " REPORT_TITLE
  read -r -p "Report description: " REPORT_DESCRIPTION

  # Report metadata
  GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S')

  # Build metrics table
  local METRICS_ROWS=""

  for i in "${!cpu_values[@]}"; do

    METRICS_ROWS+="<tr>
            <td>${timestamp_values[$i]}</td>
            <td>${cpu_values[$i]}%</td>
            <td>${mem_values[$i]}%</td>
            <td>${swap_values[$i]}%</td>
            <td>${disk_values[$i]}%</td>
        </tr>
"

  done

  # Export variables for envsubst
  export REPORT_TITLE
  export REPORT_DESCRIPTION
  export GENERATED_AT

  export CPU_MIN="$cpu_min"
  export CPU_MAX="$cpu_max"
  export CPU_AVG="$cpu_avg"

  export MEM_MIN="$mem_min"
  export MEM_MAX="$mem_max"
  export MEM_AVG="$mem_avg"

  export SWAP_MIN="$swap_min"
  export SWAP_MAX="$swap_max"
  export SWAP_AVG="$swap_avg"

  export DISK_MIN="$disk_min"
  export DISK_MAX="$disk_max"
  export DISK_LAST="$disk_last"

  export METRICS_ROWS

  # Generate report
  local OUTPUT_FILE="$OUTPUT_DIR/report_$(date '+%Y%m%d_%H%M%S').html"

  envsubst '${REPORT_TITLE} ${REPORT_DESCRIPTION} ${GENERATED_AT} ${CPU_MIN} ${CPU_MAX} ${CPU_AVG} ${MEM_MIN} ${MEM_MAX} ${MEM_AVG} ${SWAP_MIN} ${SWAP_MAX} ${SWAP_AVG} ${DISK_MIN} ${DISK_MAX} ${DISK_LAST} ${METRICS_ROWS}' \
    <"$TEMPLATE" >"$OUTPUT_FILE"

  echo "HTML report generated: $OUTPUT_FILE"
}

# Function to log metrics and store in arrays
log_metrics() {
  local timestamp="$1"
  local cpu
  local mem
  local swap
  local disk
  local answer

  cpu=$(get_cpu_usage)
  mem=$(get_mem_usage)
  swap=$(get_swap_usage)
  disk=$(get_disk_usage)

  # Store values in arrays
  timestamp_values+=("$timestamp")
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

  # Alerts: CPU insufficiency (3 consecutive cycles over 80%)
  # change to 80
  if ((cpu >= 0)); then
    consecutive_cpu_alerts=$((consecutive_cpu_alerts + 1))
  else
    consecutive_cpu_alerts=0
  fi

  if ((consecutive_cpu_alerts >= 3)); then
    send_alert "CPU insufficiency: consumo de CPU en ${cpu}%"
    send_mail "CPU insufficiency: consumo de CPU en ${cpu}%"
  fi

  # Alert: low disk remaining (< 15%)
  # change to 15
  if (((100 - disk) < 95 && disk_alert_pending == 0)); then
    disk_alert_pending=1
    send_alert "Disk insufficiency: espacio restante $((100 - disk))%"
    read -p "¿Desea eliminar archivos temporales? (s/n): " answer
    if [[ "$answer" == "s" || "$answer" == "S" ]]; then
      rm -rf /tmp/*
    fi
  fi

  # Alert: low RAM remaining (< 10%)
  # Change to 10
  if (((100 - mem) < 90)); then
    send_alert "RAM insufficiency: espacio restante de RAM en $((100 - mem))%"
    get_top_ram_processes
  fi
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

generate_html_report
