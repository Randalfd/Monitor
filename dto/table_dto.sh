#!/bin/bash

declare -A table_dto

create_table_dto() {
  table_dto=(
    [timestamp]="$1"
    [minCpu]="$2"
    [minRam]="$3"
    [minSwap]="$4"
    [minDisk]="$5"
    [lastDisk]="$6"

    [avgCpu]="$7"
    [avgRam]="$8"
    [avgSwap]="$9"

    [maxCpu]="${10}"
    [maxRam]="${11}"
    [maxSwap]="${12}"
    [maxDisk]="${13}"
  )
}

# build as create_table_dto [time] [cpu] [ram] [swap] [disk_min] [disk_last] [cpu_avg] [ram_avg] [swap_avg] [cpu_max] [ram_max] [swap_max] [disk_max]