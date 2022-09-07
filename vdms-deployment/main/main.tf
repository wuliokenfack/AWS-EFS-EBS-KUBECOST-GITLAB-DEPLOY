provider "aws" {
  region = local.aws_region
}

locals {
  cluster_name = "vdms-test-cluster"
  aws_region   = "us-east-1"
  rancher_env  = "vdms-rancher-mgmt"
  rancher_url  = "https://${jsondecode(data.aws_secretsmanager_secret_version.rancher.secret_string)["url"]}"
  rancher_admin_token = jsondecode(data.aws_secretsmanager_secret_version.rancher.secret_string)["admin_token"]

  tags = {
    "terraform" = "true",
    "env"       = "vdms-test-cluster",
  }
}

data "aws_vpc" "main" {
  tags = {                                          # Use tags of VPC and Subnet
    "Environment" = "vdms_rancher_mgmt"
  }

}

data "aws_subnet_ids" "private" {
  vpc_id = data.aws_vpc.main.id

  tags = {
    SubnetType = "private"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners = ["693703738260"] # Hardened AMI August release

  filter {
    name = "name"
    values = ["20201229_Ubuntu_2004_LTS_MKP_hardened"]
  }
}


# Key Pair
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_pem" {
  filename        = "${local.cluster_name}.pem"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

#
# Server
#
module "rke2" {
  source = "./.."

  cluster_name = local.cluster_name
  vpc_id       = data.aws_vpc.main.id
  subnets      = tolist(data.aws_subnet_ids.private.ids)

  ami                   = data.aws_ami.ubuntu.image_id # Note: Multi OS is primarily for example purposes
  ssh_authorized_keys   = [tls_private_key.ssh.public_key_openssh]
  instance_type         = "t3a.large"
  controlplane_internal = true # Note this defaults to best practice of true, but is explicitly set to public for demo purposes
  servers               = 3

  # Enable AWS Cloud Controller Manager
  enable_ccm = true

  rke2_config = <<-EOT
node-label:
  - "name=server"
  - "os=rhel8"
EOT

  tags = local.tags
}

#
# Generic agent pool
#
module "agents" {
  source = "../modules/agent-nodepool"

  name    = "generic"
  vpc_id       = data.aws_vpc.main.id
  subnets      = tolist(data.aws_subnet_ids.private.ids)

  ami                 = data.aws_ami.ubuntu.image_id 
  ssh_authorized_keys = [tls_private_key.ssh.public_key_openssh]
  spot                = true
  asg                 = { min : 2, max : 10, desired : 2 }
  instance_type       = "m5a.2xlarge"

  # Enable AWS Cloud Controller Manager and Cluster Autoscaler
  enable_ccm        = true
  enable_autoscaler = true

  rke2_config = <<-EOT
node-label:
  - "name=generic"
  - "os=rhel8"
EOT

  cluster_data = module.rke2.cluster_data

  tags = local.tags
}

#
# storage agent pool
#
module "storage_agents" {
  source = "../modules/agent-nodepool"

  name    = "storage_agents"
  vpc_id       = data.aws_vpc.main.id
  subnets      = tolist(data.aws_subnet_ids.private.ids)

  ami                 = data.aws_ami.ubuntu.image_id 
  ssh_authorized_keys = [tls_private_key.ssh.public_key_openssh]
  spot                = true
  asg                 = { min : 5, max : 10, desired : 5 }
  instance_type       = "m5a.2xlarge"

  # Enable AWS Cloud Controller Manager and Cluster Autoscaler
  is_storage_node   = true
  enable_ccm        = true
  enable_autoscaler = true

  rke2_config = <<-EOT
node-label:
  - "name=storage"
  - "storage-only=true"
node-taint:
  - "storage-only=true:NoSchedule"
EOT

  cluster_data = module.rke2.cluster_data

  tags = local.tags
}

# For demonstration only, lock down ssh access in production
resource "aws_security_group_rule" "quickstart_ssh" {
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = module.rke2.cluster_data.cluster_sg
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Generic outputs as examples
output "rke2" {
  value = module.rke2
}

# Example method of fetching kubeconfig from state store, requires aws cli and bash locally
resource "null_resource" "kubeconfig" {
  depends_on = [module.rke2]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "aws s3 cp ${module.rke2.kubeconfig_path} rke2.yaml"
  }
}

data "aws_secretsmanager_secret" "rancher" {
  name = "${local.rancher_env}-rancher-credentials"
}

data "aws_secretsmanager_secret_version" "rancher" {
  secret_id = data.aws_secretsmanager_secret.rancher.id
}

provider "rancher2" {
  api_url  = local.rancher_url
  token_key = local.rancher_admin_token
}

resource "rancher2_cluster" "cluster" {
  depends_on = [module.rke2, module.agents, module.storage_agents]
  name = local.cluster_name
  description = "rke2 cluster ${local.cluster_name}"

  enable_cluster_monitoring = true
  cluster_monitoring_input {
    answers = {
      "exporter-kubelets.https" = true
      "exporter-node.enabled" = true
      "exporter-node.ports.metrics.port" = 9796
      "exporter-node.resources.limits.cpu" = "200m"
      "exporter-node.resources.limits.memory" = "200Mi"
      "grafana.persistence.enabled" = false
      "grafana.persistence.size" = "10Gi"
      "grafana.persistence.storageClass" = "default"
      "operator.resources.limits.memory" = "500Mi"
      "operator-init.enabled" = "true"
      "prometheus.persistence.enabled" = "false"
      "prometheus.persistence.size" = "50Gi"
      "prometheus.persistence.storageClass" = "default"
      "prometheus.persistent.useReleaseName" = "true"
      "prometheus.resources.core.limits.cpu" = "1000m",
      "prometheus.resources.core.limits.memory" = "3000Mi"
      "prometheus.resources.core.requests.cpu" = "750m"
      "prometheus.resources.core.requests.memory" = "750Mi"
      "prometheus.retention" = "12h"
    }
    version = "0.1.4"
  }
}

resource "null_resource" "connect_to_rancher" {
  depends_on = [module.rke2]
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "KUBECONFIG=$(pwd)/rke2.yaml ${rancher2_cluster.cluster.cluster_registration_token.0.command}"
  }
}

# Create a new rancher2 Cluster Sync for foo-custom cluster
resource "rancher2_cluster_sync" "cluster_sync" {
  cluster_id =  rancher2_cluster.cluster.id
  wait_monitoring = rancher2_cluster.cluster.enable_cluster_monitoring
}
# Create a new rancher2 Namespace
resource "rancher2_namespace" "istio_namespace" {
  name = "istio-system"
  project_id = rancher2_cluster_sync.cluster_sync.system_project_id
  description = "istio namespace"
}

# Create a new rancher2 App deploying istio (should wait until monitoring is up and running)
resource "rancher2_app" "istio" {
  catalog_name = "system-library"
  name = "cluster-istio"
  description = "Terraform app acceptance test"
  project_id = rancher2_namespace.istio_namespace.project_id
  template_name = "rancher-istio"
  template_version = "1.5.900"
  target_namespace = rancher2_namespace.istio_namespace.name
  answers = {
    "certmanager.enabled" = false
    "enableCRDs" = true
    "galley.enabled" = true
    "gateways.enabled" = false
    "gateways.istio-ingressgateway.resources.limits.cpu" = "2000m"
    "gateways.istio-ingressgateway.resources.limits.memory" = "1024Mi"
    "gateways.istio-ingressgateway.resources.requests.cpu" = "100m"
    "gateways.istio-ingressgateway.resources.requests.memory" = "128Mi"
    "gateways.istio-ingressgateway.type" = "NodePort"
    "global.monitoring.type" = "cluster-monitoring"
    "global.rancher.clusterId" = rancher2_cluster_sync.cluster_sync.cluster_id
    "istio_cni.enabled" = "false"
    "istiocoredns.enabled" = "false"
    "kiali.enabled" = "true"
    "mixer.enabled" = "true"
    "mixer.policy.enabled" = "true"
    "mixer.policy.resources.limits.cpu" = "4800m"
    "mixer.policy.resources.limits.memory" = "4096Mi"
    "mixer.policy.resources.requests.cpu" = "1000m"
    "mixer.policy.resources.requests.memory" = "1024Mi"
    "mixer.telemetry.resources.limits.cpu" = "4800m",
    "mixer.telemetry.resources.limits.memory" = "4096Mi"
    "mixer.telemetry.resources.requests.cpu" = "1000m"
    "mixer.telemetry.resources.requests.memory" = "1024Mi"
    "mtls.enabled" = false
    "nodeagent.enabled" = false
    "pilot.enabled" = true
    "pilot.resources.limits.cpu" = "1000m"
    "pilot.resources.limits.memory" = "4096Mi"
    "pilot.resources.requests.cpu" = "500m"
    "pilot.resources.requests.memory" = "2048Mi"
    "pilot.traceSampling" = "1"
    "security.enabled" = true
    "sidecarInjectorWebhook.enabled" = true
    "tracing.enabled" = true
    "tracing.jaeger.resources.limits.cpu" = "500m"
    "tracing.jaeger.resources.limits.memory" = "1024Mi"
    "tracing.jaeger.resources.requests.cpu" = "100m"
    "tracing.jaeger.resources.requests.memory" = "100Mi"
  }
}

resource "rancher2_app_v2" "cis-benchmarks" {
  depends_on = [rancher2_cluster.cluster]
  cluster_id = rancher2_cluster_sync.cluster_sync.cluster_id
  project_id = rancher2_cluster_sync.cluster_sync.system_project_id
  name = "rancher-cis-benchmark"
  namespace = "cis-operator-system"
  repo_name = "rancher-charts"
  chart_name = "rancher-cis-benchmark"
  chart_version = "1.0.300"
}

# resource "null_resource" "k8s_replace_storage_worker_nodes" {
#   depends_on = [rancher2_cluster.cluster]
#   # triggers = {
#   #   ami_change = data.aws_ami.ubuntu
#   # }
#   provisioner "local-exec" {
#     command = "chmod +x replace_nodes.sh && ./replace_nodes.sh"

#     environment = {
#       AWS_REGION               = local.aws_region
#       UPDATING_WORKERS         = "false"
#       UPDATING_STORAGE_NODES   = "true"
#       ADMIN_TOKEN              = local.rancher_admin_token
#       NODE_ASG                 = module.storage_agents.nodepool_id
#       CLUSTER_ID               = rancher2_cluster.cluster.id
#       PROJECT_ID               = rancher2_cluster_sync.cluster_sync.system_project_id
#       RANCHER_URL              = local.rancher_url
#     }
#   }
# }


# deploy 
# resource "null_resource" "deploy_k8s_resources" {
#   depends_on = [module.rke2]
#   triggers = {
#     region       = local.aws_region
#     cluster_name = local.cluster_name
#   }


#   provisioner "local-exec" {
#     interpreter = ["bash", "-c"]
#     command     = "bash deploy.sh"

#     environment = {
#       AWS_REGION               = self.triggers.region
#       CLUSTER_NAME             = self.triggers.cluster_name
#     }
#   }
# }