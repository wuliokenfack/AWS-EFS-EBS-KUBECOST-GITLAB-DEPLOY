#!/bin/bash
set -e
exit 0
mkdir -p temp_workspace || true

export KUBECONFIG=$(pwd)/rke2.yaml
CLUSTER_AUTOSCALER_ROLE=test
CERT_MANAGER_ROLE=test


until [[ $(kubectl get nodes | grep " Ready " | grep "<none>" | wc -l) -ge 3 && $(kubectl get nodes | grep " Ready " | grep "etcd,master" | wc -l) -ge 3 ]];
do
  echo 'Waiting for cluster startup'
  sleep 15
done

echo "installing system upgrade controller"
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.6.2/system-upgrade-controller.yaml
echo "finished installing system upgrade controller"

echo "installing kube2iam"
# helm upgrade kube2iam ./kube2iam --namespace kube-system --install --wait \
#   --set AWS_REGION=$AWS_REGION
echo "installed kube2iam"

echo "installing fluentd"
kubectl create ns amazon-cloudwatch || true
kubectl annotate ns amazon-cloudwatch field.cattle.io/projectId=$PROJECT_ID --overwrite
# helm upgrade fluentd ./fluentd --namespace amazon-cloudwatch --install --wait \
#   --set AWS_REGION=$AWS_REGION \
#   --set clusterName=$CLUSTER_NAME \
#   --set logGroup=$FLUENTD_LOG_GROUP \
#   --set role=$FLUENTD_ROLE
echo "installed fluentd"

echo "installing cluster autoscaler"
helm upgrade cluster-autoscaler ./cluster-autoscaler --namespace kube-system --install --wait \
  --set AWS_REGION=$AWS_REGION \
  --set clusterName=$CLUSTER_NAME \
  --set role=$CLUSTER_AUTOSCALER_ROLE
echo "installed cluster autoscaler"


kubectl apply -f ebs-storageclass.yaml

echo "deploying rook-ceph"
kubectl create ns rook-ceph || true
kubectl annotate ns rook-ceph field.cattle.io/projectId=$PROJECT_ID --overwrite
helm upgrade rook-ceph ./rook-ceph --namespace rook-ceph --install --wait
if ! kubectl get cephclusters -n rook-ceph | grep rook ;then  
  kubectl apply -f cephcluster.yaml
  until [[ $(kubectl get cephclusters rook-ceph -n rook-ceph -o jsonpath='{.status.phase}') = "Ready" ]]; do
    echo "waiting for rook ceph cluster to start"
    sleep 10
  done
fi
helm upgrade rook-cluster ./rook-cluster --namespace rook-ceph --install --wait
echo "deployed rook-ceph"


if [[ "$INSTALL_EFS" == "true" ]]
then 
echo "deploying efs"
kubectl create ns efs || true
kubectl annotate ns efs field.cattle.io/projectId=$PROJECT_ID --overwrite
helm upgrade efs ./efs-provisioner --set efsProvisioner.efsFileSystemId=$EFS_ID --set efsProvisioner.awsRegion=$AWS_REGION --namespace efs --install --wait
echo "deployed efs"
fi


echo "deploying nginx ingress"
kubectl create ns nginx-ingress || true
kubectl annotate ns nginx-ingress field.cattle.io/projectId=$PROJECT_ID --overwrite

echo "installing certificate manager"
helm upgrade cert-manager ./cert-manager --namespace nginx-ingress --install --wait \
  --set "podAnnotations.iam\.amazonaws\.com/role"=$CERT_MANAGER_ROLE

helm upgrade nginx-ingress ./nginx-ingress --namespace nginx-ingress --install --wait \
  --set certificateHostname=$CLUSTER_HOSTNAME
echo "deploying nginx ingress"



rm -rf temp_workspace
