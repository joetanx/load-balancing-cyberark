#!/bin/bash
TYPE=$1
NAME=$2
STATE=$3
case $STATE in
  "MASTER")
    systemctl start nginx
    logger -t nginx-ha-keepalived "VRRP $TYPE $NAME changed to $STATE state"
    exit 0
    ;;
  "BACKUP"|"FAULT")
    systemctl stop nginx
    logger -t nginx-ha-keepalived "VRRP $TYPE $NAME changed to $STATE state"
    exit 0
    ;;
  *)
    logger -t nginx-ha-keepalived "Unknown state $STATE for VRRP $TYPE $NAME"
    exit 1
    ;;
esac