#!/usr/bin/env bash
# Source this: `source scripts/env.sh`

export CONTROLLER_IP=192.168.252.2
export WORKER_1_IP=192.168.252.3
export WORKER_2_IP=192.168.252.4

# Pod CIDRs (used later for networking)
export WORKER_1_POD_CIDR=10.200.1.0/24
export WORKER_2_POD_CIDR=10.200.2.0/24

# Cluster service CIDR
export SERVICE_CIDR=10.32.0.0/24
export CLUSTER_DNS=10.32.0.10

echo "Environment loaded:"
echo "  controller : $CONTROLLER_IP"
echo "  worker-1   : $WORKER_1_IP"
echo "  worker-2   : $WORKER_2_IP"
