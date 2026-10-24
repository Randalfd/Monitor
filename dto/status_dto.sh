#!/bin/bash

declare -A status_dto

create_status_dto() {
  status_dto=(
    [timestamp]="$1"
    [cpu]="$2"
    [ram]="$3"
    [swap]="$4"
    [disk]="$5"
  )
}
# build as create_status_dto [time] [cpu] [ram] [swap] [disk]
