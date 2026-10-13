variable "frontend_container_cores_num" {
  type        = number
  description = "Number of frontend cores to use on instances, this number will reflect on number of NICs attached to instance, as each weka core requires dedicated NIC"
  default     = 1
}

variable "ami_id" {
  type        = string
  description = "ami id"
}

variable "protocol" {
  type        = string
  description = "Name of the protocol."
  default     = "NFS"

  validation {
    condition     = contains(["NFS", "SMB", "S3"], var.protocol)
    error_message = "Allowed values for protocol: NFS, SMB. S3"
  }
}

variable "secondary_ips_per_nic" {
  type        = number
  description = "Number of secondary IPs per single NIC per protocol gateway virtual machine."
  default     = 2
}

variable "subnet_id" {
  type        = string
  description = "subnet id"
}

variable "gateways_number" {
  type        = number
  description = "The number of virtual machines to deploy as protocol gateways."
}

variable "cluster_name" {
  type        = string
  description = "The cluster name."
}

variable "gateways_name" {
  type        = string
  description = "The protocol group name."
}

variable "assign_public_ip" {
  type        = bool
  description = "Determines whether to assign public ip."
}

variable "weka_volume_size" {
  type        = number
  description = "The disk size."
}

variable "install_weka_url" {
  type        = string
  description = "The URL of the Weka release download tar file."

  validation {
    condition     = length(var.install_weka_url) > 0
    error_message = "The URL should not be empty."
  }
}

variable "instance_iam_profile_arn" {
  type        = string
  description = "Instance IAM profile ARN"
}

variable "sg_ids" {
  type        = list(string)
  default     = []
  description = "Security group ids"
}

variable "placement_group_name" {
  type        = string
  description = "Placement group name"
  default     = ""
}

variable "tags_map" {
  type        = map(string)
  default     = { "env" : "dev", "creator" : "tf" }
  description = "A map of tags to assign the same metadata to all resources in the environment. Format: key:value. Note: Manually tagged resources will be overridden by Terraform apply."
}

variable "instance_type" {
  type        = string
  description = "The virtual machine type (sku) to deploy"
}

variable "key_pair_name" {
  type        = string
  description = "Ssh key pair name to pass to the instances."
}

variable "weka_cluster_size" { # tflint-ignore: terraform_unused_declarations
  type        = number
  description = "[Deprecated] Number of backends in the weka cluster"
  default     = 0
}

variable "proxy_url" {
  type        = string
  description = "Weka proxy url"
  default     = ""
}

variable "secret_prefix" {
  type        = string
  description = "Prefix of secrets"
}

variable "setup_protocol" {
  type        = bool
  description = "Configure protocol, default value is False"
}

variable "smbw_enabled" {
  type        = bool
  default     = true
  description = "Enable SMBW protocol."
}

variable "smb_cluster_name" {
  type        = string
  description = "The name of the SMB setup."
  default     = "Weka-SMB"

  validation {
    condition     = length(var.smb_cluster_name) > 0 && length(var.smb_cluster_name) <= 15
    error_message = "The SMB cluster name must be between 1 and 15 characters long."
  }
}

variable "smb_domain_name" {
  type        = string
  description = "The domain to join the SMB cluster to."
  default     = ""
}

variable "deploy_lambda_name" {
  type        = string
  description = "The name of the deploy function"
}

variable "report_lambda_name" {
  type        = string
  description = "The name of the report function"
}

variable "fetch_lambda_name" {
  type        = string
  description = "The name of the fetch function"
}

variable "status_lambda_name" {
  type        = string
  description = "The name of the status function"
}

variable "clusterize_lambda_name" {
  type        = string
  description = "The name of the clusterize function"
}

variable "clusterize_finalization_lambda_name" {
  type        = string
  description = "The name of the clusterize finalization function"
}

variable "join_nfs_finalization_lambda_name" {
  type        = string
  description = "The name of the join finalization function"
}

variable "metadata_http_tokens" {
  type        = string
  default     = "required"
  description = "Whether or not the metadata service requires session tokens, also referred to as Instance Metadata Service Version 2 (IMDSv2)"
}

variable "ebs_kms_key_id" {
  type        = string
  default     = ""
  description = "The ARN of the AWS Key Management Service"
}

variable "ebs_encrypted" {
  type        = bool
  default     = true
  description = "Enables EBS encryption on the volume"
}

variable "use_placement_group" {
  type        = bool
  default     = true
  description = "Use cluster placement group for clients. Note: If not using a cluster placement group, the instances will most likely be spread out across the underlying AWS infrastructure, resulting in not getting the maximum performance from the WEKA cluster"
}

variable "capacity_reservation_id" {
  type        = string
  default     = null
  description = "The ID of the capacity reservation in which to run the clients"
}

variable "iam_base_name" {
  type        = string
  description = "The prefix of the IAM role"
  default     = null
}

variable "root_volume_size" {
  type        = number
  default     = null
  description = "root disk size."
}

variable "ena_express_enabled" {
  type        = bool
  default     = false
  description = "Enable ENA Express (AWS SRD) on the protocol gateways' primary (kernel/management) network interface and apply the matching MTU, ring and TCP tuning on the host. Requires an instance type that supports ENA Express."
}

variable "ena_express_udp_enabled" {
  type        = bool
  default     = false
  description = "Also carry UDP traffic over ENA Express on the primary network interface. Only applies when ena_express_enabled is true."
}

variable "ena_express_mtu" {
  type        = number
  default     = 8900
  description = "MTU applied to the primary network interface when ENA Express is enabled. AWS recommends 8800-8900; ENA Express does not carry packets larger than 8900 bytes."

  validation {
    condition     = var.ena_express_mtu >= 1500 && var.ena_express_mtu <= 8900
    error_message = "ena_express_mtu must be between 1500 and 8900."
  }
}
