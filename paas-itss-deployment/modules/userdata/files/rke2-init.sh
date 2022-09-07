#!/bin/sh

# deleting aws credentials built with the AMI
sudo rm -f /root/.aws/credentials

export TYPE="${type}"
export CCM="${ccm}"

# info logs the given argument at info log level.
info() {
    echo "[INFO] " "$@"
}

# warn logs the given argument at warn log level.
warn() {
    echo "[WARN] " "$@" >&2
}

# fatal logs the given argument at fatal log level.
fatal() {
    echo "[ERROR] " "$@" >&2
    exit 1
}

config() {
  mkdir -p "/etc/rancher/rke2"
  cat <<EOF > "/etc/rancher/rke2/config.yaml"
# Additional user defined configuration
${config}
EOF
}

append_config() {
  echo $1 >> "/etc/rancher/rke2/config.yaml"
}

# The most simple "leader election" you've ever seen in your life
elect_leader() {
  # Fetch other running instances in ASG
  instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  asg_name=$(aws autoscaling describe-auto-scaling-instances --instance-ids "$instance_id" --query 'AutoScalingInstances[*].AutoScalingGroupName' --output text)
  instances=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$asg_name" --query 'AutoScalingGroups[*].Instances[?HealthStatus==`Healthy`].InstanceId' --output text)

  # Simply identify the leader as the first of the instance ids sorted alphanumerically
  leader=$(echo $instances | tr ' ' '\n' | sort -n | head -n1)

  info "Current instance: $instance_id | Leader instance: $leader"

  if [ $instance_id = $leader ]; then
    SERVER_TYPE="leader"
    info "Electing as cluster leader"
  else
    info "Electing as joining server"
  fi
}

identify() {
  # Default to server
  SERVER_TYPE="server"

  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  supervisor_status=$(curl --write-out '%%{http_code}' -sk --output /dev/null https://${server_url}:9345/ping)

  if [ $supervisor_status -ne 200 ]; then
    info "API server unavailable, performing simple leader election"
    elect_leader
  else
    info "API server available, identifying as server joining existing cluster"
  fi
}

cp_wait() {
  while true; do
    supervisor_status=$(curl --write-out '%%{http_code}' -sk --output /dev/null https://${server_url}:9345/ping)
    if [ $supervisor_status -eq 200 ]; then
      info "Cluster is ready"

      # Let things settle down for a bit, not required
      # TODO: Remove this after some testing
      sleep 10
      break
    fi
    info "Waiting for cluster to be ready..."
    sleep 10
  done
}

fetch_token() {
  info "Fetching rke2 join token..."

  # Validate aws caller identity, fatal if not valid
  if ! aws sts get-caller-identity 2>/dev/null; then
    fatal "No valid aws caller identity"
  fi

# Installing AWS CLI

cd /tmp
sudo -y apt install curl wget unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install --update



  # Either
  #   a) fetch token from s3 bucket
  #   b) fail
  if token=$(aws s3 cp "s3://${token_bucket}/${token_object}" - 2>/dev/null);then
    info "Found token from s3 object"
  else
    fatal "Could not find cluster token from s3"
  fi

  echo "token: $${token}" >> "/etc/rancher/rke2/config.yaml"
}

upload() {
  # Wait for kubeconfig to exist, then upload to s3 bucket
  retries=10

  while [ ! -f /etc/rancher/rke2/rke2.yaml ]; do
    sleep 10
    if [ "$retries" = 0 ]; then
      fatal "Failed to create kubeconfig"
    fi
    ((retries--))
  done

  # Replace localhost with server url and upload to s3 bucket
  sed "s/127.0.0.1/${server_url}/g" /etc/rancher/rke2/rke2.yaml | aws s3 cp - "s3://${token_bucket}/rke2.yaml"
}

pre_userdata() {
  info "Beginning user defined pre userdata"
  ${pre_userdata}
  info "Beginning user defined pre userdata"
}

post_userdata() {
  info "Beginning user defined post userdata"
  ${post_userdata}
  info "Ending user defined post userdata"
}

{
  pre_userdata

  config
  fetch_token

  if [ $CCM = "true" ]; then
    append_config 'cloud-provider-name: "aws"'
  fi

  if [ $TYPE = "server" ]; then
    # Initialize server
    identify

    cat <<EOF >> "/etc/rancher/rke2/config.yaml"
tls-san:
  - ${server_url}
EOF

    if [ $SERVER_TYPE = "server" ]; then
      append_config 'server: https://${server_url}:9345'
      # Wait for cluster to exist, then init another server
      cp_wait
    fi

    systemctl enable rke2-server
    systemctl daemon-reload
    systemctl start rke2-server

    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    export PATH=$PATH:/var/lib/rancher/rke2/bin

    # Upload kubeconfig to s3 bucket
    upload

  else
    append_config 'server: https://${server_url}:9345'

    # Default to agent
    systemctl enable rke2-agent
    systemctl daemon-reload
    systemctl start rke2-agent
  fi

  post_userdata
}

# configuring ssh public key for nodes 

sudo mkdir /home/ubuntu/.ssh
sudo echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDJnfbmzYMw8dAjnahvIgq5aShSsS9DWWpeL6EmPyCWKuaW8XOVWxJhcLDtGoGoL5gt/zt9ODT5TysNgGTIlwUEMBwohBUIURgHj7/oCpaiJJIFFs4eccJds/Hj213jV3BO3GSQ0suaEkDslbkqu2T8ufipfLRahWFuylKYsYyJp2v2PTq/uTuRx2Jd+XOG5mmL6HRgvuF+qBNQem796XSc3eRicIrQ3UoLHYKlxua4gejztLQJw+RTPxt1vbPziqgTGP/2ru3NH7T8xdGOm7jGrsMtvssQ7QSnSuJbTsk587mr2L654m4pB7Xae9BNCQTDFZC4T+F3Jb7fsn8ub/8TDneaN62lIWQuBHPlBdow/uUYRp5j12qDJVmVpGRjSWc8AePVbKvgETgU9+sv4VGuCAdrgzjwEFMx7PlT2SkOZyYCqg+mukukZVOhvetyHwvZiQ1X5uTmjXsmfiISQAZM8K8qIPEOWbGClPqhuZ8zOaekSjxJj3I559WD2CpAvdW/ntacabnJDWVgzIvy1mDoESDgKD3NllXgbb2JdL8rr+4+DaJzaPmuioT9Lj2Qf3NUUEC3SmHkEMTw6xCX1s1e3cJA4Z2VJj/kBKDzkud832/BbXhGdzDudMcEO6J+LK9Qz+xwxuRLt5sj8dJDGUxFKe5sL8roBv0Th24yZk0LUQ==" > /home/ubuntu/.ssh/authorized_keys
sudo systemctl restart sshd

# Installing nfs-common package needed for EFS plugin

sudo apt install uuid nfs-common -y

# Configuring logs backup to S3

if [ -f /etc/rancher/rke2/rke2.yaml ]; then
echo "0 2 * * * sudo rke2 etcd-snapshot --s3 --s3-bucket=jadeuc-etcd-backups --s3-folder=jadeuc-itss" >> /var/spool/cron/crontabs/root
else
echo "this is a worker Node, so no ETCD backup to configure"
fi

# Installing MaCafee agent

sudo apt-get update -y
sudo apt-get install wget -y
sudo apt-get install unzip -y
wget -O /var/tmp/install.sh https://ept-relay-agent.s3.amazonaws.com/agentPackages_5.7.5_05APR/installdeb.sh
sudo chmod +x /var/tmp/install.sh
sudo bash /var/tmp/install.sh -i -r -R 192.168.254.30:591
wait
########Please run below command once agent install is done#######
/opt/McAfee/agent/bin/maconfig -custom -prop1 "AWS.IaaS.IL2.JSOC-NGA.JSOC"
wait
sleep 5 &
####Also please run below command and check LastPolicyUpdateTime###
/opt/McAfee/agent/bin/cmdagent -i
echo $(date +%T)
wait
echo $(date +%T)
echo "This McAfee install process has completed"

# Setting up ACAS key

sudo useradd -m acasuser -p --disabled-password
sudo mkdir /home/acasuser/.ssh
sudo usermod -aG sudo acasuser
sudo echo "acasuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
sudo echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzIc3Doh0Pg7L1BgQ3GDxaN/Fs6v/t4fVESgksTDx84T0Vq64vBML2qckLGohvdTh77gE8fONPwhjIfx5DVdAqfEL/Fy41HuQcFslNP6R1/sgm+o2t/Xq2z9nZz48xar+qOce8uz+a6mj1TXGIkA1h6jEQqWgztf5oNyzyjweRd/aUV/I7yJ4yAmAFZtkSAD1OLzFSrAK3jcVMdOkt4xR8ys+7D/2My1L3v85sm4j3KO5E+wG5QfTLxllNT2RXOSahNmjM5EnW/1ODUuGtcqxthh6fvgb/jdaEs1z+iP7CfwtqVIiAoNnmY23Rf+N448o7TRur8ZWAr+U0TZKtcf96ZuDDVrkP/idliWmWAk7CffjllRbIN8PkzNpUefJq3qQvnDm2fvEP2zeSTOCpewW5+aaTMMTTgOibCP8lW1IWJQ24C10agtXH2uo1aNcsyznI+jT9jJIQRVVD3tygJLdViWyoitmwb7SRqQAKwid06zvPC5xLPyEGQtwJolE8XPE= acasuser@ip-10-4-0-128" >> /home/acasuser/.ssh/authorized_keys
sudo chown -R acasuser:acasuser /home/acasuser/.ssh/
sudo chmod 0600 /home/acasuser/.ssh/authorized_keys
sudo chmod 0700 /home/acasuser/.ssh