#!/bin/bash

if [ -z "$1" ] && [ -z "$2"] && [ -z "$3"] && [ -z "$4" ]; then
  echo "Usage: ./create_cluster.sh <min_mem_instances> <min_ebs_instances> <proxy_instances> <benchmark_instances> {<path-to-ssh-key>}"
  echo ""
  echo "If no SSH key is specified, it is assumed that we are using the default SSH key (/home/ubuntu/.ssh/id_rsa). We assume that the corresponding public key has the same name and ends in .pub."
  exit 1
fi

add_nodes() {
  if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then 
    echo "Expected usage: add_nodes <num-memory-nodes> <num-ebs-nodes> <num-proxy-nodes> <num-benchmark-nodes>."
    exit 1
  fi

  IDS=()
  NODE_TYPE=()
  # memory node(s)
  for i in $(seq 1 $1); do
    UUID=`tr -dc 'a-z0-9' < /dev/urandom | head -c 16`
    ./add_server.sh m $UUID
    IDS+=( $UUID )
    NODE_TYPE+=( m )
  done
  # ebs node(s)
  for i in $(seq 1 $2); do
    UUID=`tr -dc 'a-z0-9' < /dev/urandom | head -c 16`
    ./add_server.sh e $UUID
    IDS+=( $UUID )
    NODE_TYPE+=( e )
  done
  # proxy node(s)
  for i in $(seq 1 $3); do
    UUID=`tr -dc 'a-z0-9' < /dev/urandom | head -c 16`
    ./add_server.sh p $UUID
    IDS+=( $UUID )
    NODE_TYPE+=( p )
  done
  # benchmark node(s)
  for i in $(seq 1 $4); do
    UUID=`tr -dc 'a-z0-9' < /dev/urandom | head -c 16`
    ./add_server.sh b $UUID
    IDS+=( $UUID )
    NODE_TYPE+=( b )
  done

  kops update cluster --name ${NAME} --yes > /dev/null 2>&1
  kops validate cluster > /dev/null 2>&1
  while [ $? -ne 0 ]
  do
    kops validate cluster > /dev/null 2>&1
  done

  for i in ${!IDS[@]}; do
    echo $i
    echo ${NODE_TYPE[$i]}
    echo ${IDS[$i]}
    ./add_node.sh ${NODE_TYPE[$i]} ${IDS[$i]}
  done
}

if [ -z "$5" ]; then
  SSH_KEY=/home/ubuntu/.ssh/id_rsa
else 
  SSH_KEY=$5
fi

export NAME=kvs.k8s.local
export KOPS_STATE_STORE=s3://tiered-storage-state-store

echo "Creating cluster object..."
kops create cluster --zones us-east-1a --ssh-public-key ${SSH_KEY}.pub ${NAME} > /dev/null 2>&1
# delete default instance group that we won't use
kops delete ig nodes --name ${NAME} --yes > /dev/null 2>&1

# add the kops node
echo "Adding general instance group"
sed "s|CLUSTER_NAME|$NAME|g" yaml/igs/general-ig.yml > tmp.yml
kops create -f tmp.yml > /dev/null 2>&1
rm tmp.yml

# create the cluster with just the proxy instance group
echo "Creating cluster on AWS..."
kops update cluster --name ${NAME} --yes > /dev/null 2>&1

# wait until the cluster was created
echo "Validating cluster..."
kops validate cluster > /dev/null 2>&1
while [ $? -ne 0 ]
do
  kops validate cluster > /dev/null 2>&1
done

# create the kops pod
echo "Creating management pods"
sed "s|ACCESS_KEY_ID_DUMMY|$AWS_ACCESS_KEY_ID|g" yaml/pods/kops-pod.yml > tmp.yml
sed -i "s|SECRET_KEY_DUMMY|$AWS_SECRET_ACCESS_KEY|g" tmp.yml
sed -i "s|KOPS_BUCKET_DUMMY|$KOPS_STATE_STORE|g" tmp.yml
sed -i "s|CLUSTER_NAME|$NAME|g" tmp.yml
kubectl create -f tmp.yml > /dev/null 2>&1
rm tmp.yml

MGMT_IP=`kubectl get pods -l role=kops -o jsonpath='{.items[*].status.podIP}' | tr -d '[:space:]'`
while [ "$MGMT_IP" = "" ]; do
  MGMT_IP=`kubectl get pods -l role=kops -o jsonpath='{.items[*].status.podIP}' | tr -d '[:space:]'`
done
sed "s|MGMT_IP_DUMMY|$MGMT_IP|g" yaml/pods/monitoring-pod.yml > tmp.yml
kubectl create -f tmp.yml > /dev/null 2>&1
rm tmp.yml

echo "Creating $3 proxy node(s)..."
add_nodes 0 0 $3 0

# wait for all proxies to be ready
PROXY_IPS=`kubectl get pods -l role=proxy -o jsonpath='{.items[*].status.podIP}'`
PROXY_IP_ARR=($PROXY_IPS)
while [ ${#PROXY_IP_ARR[@]} -ne $3 ]; do
  PROXY_IPS=`kubectl get pods -l role=proxy -o jsonpath='{.items[*].status.podIP}'`
  PROXY_IP_ARR=($PROXY_IPS)
done

echo "Creating $1 memory node(s), $2 ebs node(s), and $4 benchmark node(s)..."

add_nodes $1 $2 0 $4

# copy the SSH key into the management node... doing this later because we need
# to wait for the pod to come up
kubectl cp $SSH_KEY kops-pod:/root/.ssh/id_rsa
kubectl cp ${SSH_KEY}.pub kops-pod:/root/.ssh/id_rsa.pub

echo "Cluster is now ready for use!"

# TODO: once we have a yaml config file, we will have to set the values in each
# of the pod scripts for the replication factors, etc. otherwise, we'll end up
# with weird inconsistencies