#!/bin/bash

declare -A alert_dto

create_alert_dto() {
  alert_dto[problem]="$1"
  alert_dto[timestamp]="$2"
}

# build as create_alert_dto [problem] [timestamp]
