#!/bin/bash
rancher login -t $ADMIN_TOKEN --context $PROJECT_ID $RANCHER_URL --skip-verify
export KUBECONFIG=$(pwd)/rke2.yaml

if [[ ! $(kubectl get ns rook-ceph | grep d | wc -l) -eq 1 ]]; then
  echo "cluster not ready to cycle nodes"
  rm -rf temp_workspace
  exit 0
fi

OLD_INSTANCES=($(aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values=$NODE_ASG Name=tag:Update-status,Values=old Name=instance-state-name,Values=running | jq -r .Reservations[].Instances[].InstanceId ))

if [ ${#OLD_INSTANCES[@]} -eq 0 ]; then
  OLD_INSTANCES=($(aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values=$NODE_ASG Name=instance-state-name,Values=running | jq -r .Reservations[].Instances[].InstanceId ))
  echo "tagging instances to be replaced as old"
  aws ec2 create-tags --resources ${OLD_INSTANCES[*]} --tags Key=Update-status,Value=old 
else
  echo "Seems some instances are still tagged as old, continuing last running update."
fi
INITIAL_SIZE=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $NODE_ASG | jq .AutoScalingGroups[].DesiredCapacity)

if $UPDATING_WORKERS; then
  if [ $INITIAL_SIZE -ge 6 ]; then
    echo "no neeed to scale cluster up for update"
  else
    echo "scaling cluster up for update"
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name $NODE_ASG --min-size 6
    sleep 300
    while ! rancher clusters | grep $CLUSTER_ID | grep active
    do
      echo "waiting for cluster to finish scaling up"
      rancher inspect $CLUSTER_ID | jq -r .transitioningMessage
      sleep 10
    done
  fi 
fi

while ! rancher clusters | grep $CLUSTER_ID | grep active
do
  echo "waiting for cluster to be in a ready state"
  rancher inspect $CLUSTER_ID | jq -r .transitioningMessage
  sleep 10
done
echo "cluster is now ready"

for INSTANCE in "${OLD_INSTANCES[@]}"
do
  K8S_NODE=$(aws ec2 describe-instances --instance-ids $INSTANCE | jq .Reservations[].Instances[].PrivateDnsName -r )
  echo "Removing node $K8S_NODE"
  kubectl drain $K8S_NODE --ignore-daemonsets --delete-local-data --timeout=20s 
  kubectl drain $K8S_NODE --ignore-daemonsets --disable-eviction --delete-local-data
  kubectl delete node $K8S_NODE
  aws ec2 terminate-instances --instance-ids $INSTANCE
  echo "Removed node $K8S_NODE"


  ALL_ASG_INSTANCES=($(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $NODE_ASG | jq -r .AutoScalingGroups[].Instances[].InstanceId))
  NEW_INSTANCES=$(aws ec2 describe-instance-status --instance-ids ${ALL_ASG_INSTANCES[*]} --filters Name=instance-status.reachability,Values=initializing | jq -r .InstanceStatuses)
  while [ $(echo $NEW_INSTANCES | wc -w) -eq 1 ]
  do
    echo "waiting for new instance"
    ALL_ASG_INSTANCES=($(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $NODE_ASG | jq -r .AutoScalingGroups[].Instances[].InstanceId))
    NEW_INSTANCES=$(aws ec2 describe-instance-status --instance-ids ${ALL_ASG_INSTANCES[*]} --filters Name=instance-status.reachability,Values=initializing | jq -r .InstanceStatuses)
    sleep 10
  done
  NEW_INSTANCE=$(echo $NEW_INSTANCES | jq -r .[].InstanceId)
  NEW_K8S_NODE=$(aws ec2 describe-instances --instance-ids $NEW_INSTANCE | jq .Reservations[].Instances[].PrivateDnsName -r )
  echo "Instance $NEW_INSTANCE starting, now waiting for $NEW_K8S_NODE to join cluster"

  while ! kubectl get node $NEW_K8S_NODE | grep " Ready "
  do
    echo "waiting for $NEW_K8S_NODE to join cluster"
    NEW_INSTANCE=$(aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values=$NODE_ASG Name=instance-state-name,Values=pending | jq -r .Reservations[].Instances[].InstanceId)
    sleep 10
  done
  echo "$NEW_K8S_NODE has joined cluster"

  while ! rancher clusters | grep $CLUSTER_ID | grep active
  do
    echo "waiting for cluster to finish updating:"
    rancher inspect $CLUSTER_ID | jq -r .transitioningMessage
    sleep 10
  done
  echo "cluster has finished updating"

  i=0
  
  while [[ $(kubectl get pods --field-selector=status.phase=Pending -A --output json | jq -j '.items | length') -ne "0" ]]
  do
    echo "Still waiting on the following pending pods"
    kubectl get pods --field-selector=status.phase=Pending -A --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}'
    sleep 10
    ((i++))
    if [[ "$i" == '12' ]]; then
      break
    fi
  done

  if $UPDATING_STORAGE_NODES ;then  
    until [[ $(kubectl get cephclusters rook-ceph -n rook-ceph -o jsonpath='{.status.ceph.health}') = "HEALTH_OK" ]]; do
      echo "waiting for rook ceph cluster to be healthy"
      sleep 10
    done
    echo "rook ceph cluster healthy"
  fi
  echo "no more pending pods, cluster is ready!"
done

if $UPDATING_WORKERS; then
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name $NODE_ASG --min-size $INITIAL_SIZE
fi


