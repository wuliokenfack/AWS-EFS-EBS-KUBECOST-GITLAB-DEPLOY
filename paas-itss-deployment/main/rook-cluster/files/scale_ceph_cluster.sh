#!/bin/bash
curl -LO https://storage.googleapis.com/kubernetes-release/release/v1.18.0/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl

while true
do

  BUFFER_PRETTY=1Ti
  /usr/local/bin/toolbox.sh --skip-watch

  CURRENT_CLUSTER_SIZE=$(ceph status -f json | jq .pgmap.bytes_total | numfmt --to=iec-i)
  BYTES_AVAILABLE=$(ceph status -f json | jq .pgmap.bytes_avail)
  BYTES_AVAILABLE_PRETTY=$(echo $BYTES_AVAILABLE | numfmt --to=iec-i)

  BUFFER_BYTES=$(echo $BUFFER_PRETTY | numfmt --from=iec-i)

  echo "Space available: $BYTES_AVAILABLE_PRETTY"

  if [ "$BYTES_AVAILABLE" -le "$BUFFER_BYTES" ]; then
    echo "Needs to expand, space available is $BYTES_AVAILABLE_PRETTY, which is less than buffer size $BUFFER_PRETTY"
    CURRENT_DEVICE_COUNT=$(kubectl get cephclusters.ceph.rook.io rook-ceph -n rook-ceph -o jsonpath='{.spec.storage.storageClassDeviceSets[0].count}')
    DESIRED_DEVICE_COUNT=$(($CURRENT_DEVICE_COUNT+5))
    echo "Updating device count. Updating from $CURRENT_DEVICE_COUNT to $DESIRED_DEVICE_COUNT"
    kubectl patch cephclusters rook-ceph -n rook-ceph --type='json' -p='[{"op": "replace", "path": "/spec/storage/storageClassDeviceSets/0/count", "value":'"$DESIRED_DEVICE_COUNT"'}]'

    until [ $(ceph status -f json | jq .osdmap.num_in_osds) -eq "$DESIRED_DEVICE_COUNT" ]; do
          echo "Waitng for cluster scale up"
          sleep 10
    done
  
    BYTES_AVAILABLE_PRETTY=$(ceph status -f json | jq .pgmap.bytes_avail | numfmt --to=iec-i)
    echo "Cluster scaled up, $BYTES_AVAILABLE_PRETTY now available"

  else
    echo "NO NEED TO EXPAND"
    sleep 30
  fi
done