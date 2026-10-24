#!/bin/bash

declare -A table_dto

create_table_dto() {
  table_dto=(
    [timestamp]="$1"
    [minCpu]="$2"
    [minRam]="$3"
    [minSwap]="$4"
    [minDisk]="$5"

    [avgCpu]="$6"
    [avgRam]="$7"
    [avgSwap]="$8"
    [avgDisk]="$9"

    [maxCpu]="$10"
    [maxRam]="$11"
    [maxSwap]="$12"
    [maxDisk]="$13"
  )
}

# build as createtable_dto [time] [cpu] [ram] [swap] [disk] [cpu] [ram] [swap] [disk] [cpu] [ram] [swap] [disk]
