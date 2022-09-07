variable "cluster_name" {
  description = "Name of the rkegov cluster to create"
  type        = string
  default     = "paas-staging-reborn"
}

variable "vpc_id" {
  description = "VPC ID to create resources in"
  type        = string
  default     = "vpc-02ed1479916ac45dd"
}

variable "agentname" {
  type        = string
  default     = ""
}

variable "subnets" {
  description = "List of subnet IDs to create resources in"
  type        = list(string)
  default     = ["subnet-026da1b784844d75b", "subnet-05bedb3aba5079852"]
}

variable "tags" {
  description = "Map of tags to add to all resources created"
  default     = {}
  type        = map(string)
}

#
# Server pool variables
#
variable "instance_type" {
  type        = string
  default     = "c5.xlarge"
  description = "Server pool instance type"
}

variable "ami" {
  description = "Server pool ami"
  type        = string
  default     = "ami-070d023e26692d2c1"
}

variable "iam_instance_profile" {
  description = "Server pool IAM Instance Profile, created if left blank"
  type        = string
  default     = ""
}

variable "block_device_mappings" {
  description = "Server pool block device mapping configuration"
  type = object({
    size      = number
    encrypted = bool
  })

  default = {
    "size"      = 50
    "encrypted" = true
  }
}

variable "servers" {
  description = "Number of servers to create"
  type        = number
  default     = 3
}

variable "spot" {
  description = "Toggle spot requests for server pool"
  type        = bool
  default     = false
}

variable "ssh_authorized_keys" {
  description = "Server pool list of public keys to add as authorized ssh keys"
  type        = list(string)
  default     = []
}

#
# Controlplane Variables
#
variable "controlplane_enable_cross_zone_load_balancing" {
  description = "Toggle between controlplane cross zone load balancing"
  default     = true
  type        = bool
}

variable "controlplane_internal" {
  description = "Toggle between public or private control plane load balancer"
  default     = true
  type        = bool
}

variable "controlplane_allowed_cidrs" {
  description = "Server pool security group allowed cidr ranges"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

#
# RKE2 Variables
#
variable "rke2_version" {
  description = "Version to use for RKE2 server nodes"
  type        = string
  default     = "v1.21.5+rke2r1"
}

variable "rke2_config" {
  description = "Server pool additional configuration passed as rke2 config file, see https://docs.rke2.io/install/install_options/server_config for full list of options"
  type        = string
  default     = ""
}

variable "download" {
  description = "Toggle best effort download of rke2 dependencies (rke2 and aws cli), if disabled, dependencies are assumed to exist in $PATH"
  type        = bool
  default     = true
}

variable "pre_userdata" {
  description = "Custom userdata to run immediately before rke2 node attempts to join cluster, after required rke2, dependencies are installed"
  type        = string
  default     = ""
}

variable "post_userdata" {
  description = "Custom userdata to run immediately after rke2 node attempts to join cluster"
  type        = string
  default     = ""
}

variable "enable_ccm" {
  description = "Toggle enabling the cluster as aws aware, this will ensure the appropriate IAM policies are present"
  type        = bool
  default     = false
}