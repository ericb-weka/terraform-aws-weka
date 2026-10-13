data "aws_region" "current" {}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

data "aws_ami" "amzn_ami" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-kernel-6.1-x86_64"]
  }
}

# Fails the plan early if ENA Express is requested on an instance type that
# does not support it (e.g. the default c5n.2xlarge).
data "aws_ec2_instance_type" "ena_express" {
  count         = var.ena_express_enabled ? 1 : 0
  instance_type = var.instance_type

  lifecycle {
    postcondition {
      condition     = self.ena_srd_supported
      error_message = "ENA Express is enabled but instance type ${var.instance_type} does not support it. See https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ena-express.html#ena-express-supported-instance-types"
    }
  }
}

data "aws_ami" "provided_ami" {
  count = var.ami_id != null ? 1 : 0
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}

locals {
  # Merge user-provided tags with required aws-apn-id tag
  tags = merge(
    var.tags_map,
    {
      aws-apn-id = "pc:epkj0ftddjwa38m3oq9umjjlm"
    }
  )
  region    = data.aws_region.current.region
  tags_dest = ["instance", "network-interface", "volume"]

  instance_iam_profile_arn = var.instance_iam_profile_arn != "" ? var.instance_iam_profile_arn : aws_iam_instance_profile.this[0].arn

  init_script = templatefile("${path.module}/init.sh", {
    nics_num              = var.frontend_container_cores_num + 1
    subnet_id             = var.subnet_id
    region                = local.region
    groups                = join(" ", var.sg_ids)
    weka_log_group_name   = "/wekaio/${var.gateways_name}"
    proxy_url             = var.proxy_url
    deploy_lambda_name    = var.deploy_lambda_name
    secondary_ips_per_nic = var.secondary_ips_per_nic
    protocol              = lower(var.protocol)
    eni_tags              = jsonencode([for k, v in local.tags : { Key = k, Value = v }])
  })

  setup_init_protocol_script = templatefile("${path.module}/protocol_setup.sh", {
    gateways_number = var.gateways_number
    gateways_name   = var.gateways_name
    region          = local.region
    protocol        = var.protocol
    smbw_enabled    = var.smbw_enabled
  })

  setup_smb_protocol_script = templatefile("${path.module}/setup_smb.sh", {
    cluster_name                 = var.smb_cluster_name
    domain_name                  = var.smb_domain_name
    smbw_enabled                 = var.smbw_enabled
    gateways_number              = var.gateways_number
    gateways_name                = var.gateways_name
    frontend_container_cores_num = var.frontend_container_cores_num
    region                       = local.region
  })

  setup_s3_protocol_script = file("${path.module}/setup_s3.sh")

  smb_protocol_script = var.protocol == "SMB" ? local.setup_smb_protocol_script : ""

  s3_protocol_script = var.protocol == "S3" ? local.setup_s3_protocol_script : ""

  setup_protocol_script = var.setup_protocol ? compact([local.setup_init_protocol_script, local.smb_protocol_script, local.s3_protocol_script]) : []

  # ENA Express host tuning runs ahead of init.sh, only when enabled, so the
  # user data is unchanged for existing deployments.
  ena_express_script = var.ena_express_enabled ? [templatefile("${path.module}/ena_express.sh", { mtu = var.ena_express_mtu })] : []

  custom_data_parts = concat(local.ena_express_script, [local.init_script], local.setup_protocol_script)

  custom_data          = join("\n", local.custom_data_parts)
  placement_group_name = var.use_placement_group ? var.placement_group_name == null ? aws_placement_group.this[0].name : var.placement_group_name : null
  root_device_name     = var.ami_id != null ? data.aws_ami.provided_ami[0].root_device_name : data.aws_ami.amzn_ami[0].root_device_name
}

resource "aws_placement_group" "this" {
  count    = var.use_placement_group && var.placement_group_name == null ? 1 : 0
  name     = "${var.gateways_name}-placement-group"
  strategy = "cluster"
  tags     = local.tags
}

resource "aws_launch_template" "this" {
  name                                 = "${var.gateways_name}-launch-template"
  disable_api_termination              = true
  disable_api_stop                     = true
  ebs_optimized                        = true
  image_id                             = var.ami_id != null ? var.ami_id : data.aws_ami.amzn_ami[0].id
  instance_initiated_shutdown_behavior = "terminate"
  instance_type                        = var.instance_type
  key_name                             = var.key_pair_name
  update_default_version               = true

  block_device_mappings {
    device_name = "/dev/sdp"
    ebs {
      volume_size           = var.weka_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = var.ebs_encrypted
      kms_key_id            = var.ebs_kms_key_id
    }
  }

  block_device_mappings {
    device_name = local.root_device_name
    ebs {
      volume_size = var.root_volume_size
      encrypted   = var.ebs_encrypted
      kms_key_id  = var.ebs_kms_key_id
    }
  }

  credit_specification {
    cpu_credits = "standard"
  }

  iam_instance_profile {
    arn = local.instance_iam_profile_arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.metadata_http_tokens
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  network_interfaces {
    associate_public_ip_address = var.assign_public_ip
    delete_on_termination       = true
    device_index                = 0
    security_groups             = var.sg_ids
    subnet_id                   = var.subnet_id

    # ENA Express (SRD) on the primary (kernel/management) ENI. The DPDK ENIs
    # attached later by init.sh are not affected.
    dynamic "ena_srd_specification" {
      for_each = var.ena_express_enabled ? [1] : []
      content {
        ena_srd_enabled = true
        ena_srd_udp_specification {
          ena_srd_udp_enabled = var.ena_express_udp_enabled
        }
      }
    }
  }

  placement {
    availability_zone = data.aws_subnet.selected.availability_zone
    group_name        = local.placement_group_name
  }

  # Use dynamic block to prevent drift when capacity_reservation_id is null/empty
  # AWS doesn't store empty capacity reservation blocks, so we only include this block when there's an actual ID
  dynamic "capacity_reservation_specification" {
    for_each = var.capacity_reservation_id != null && var.capacity_reservation_id != "" ? [1] : []
    content {
      capacity_reservation_target {
        capacity_reservation_id = var.capacity_reservation_id
      }
    }
  }

  dynamic "tag_specifications" {
    for_each = local.tags_dest
    content {
      resource_type = tag_specifications.value
      tags = merge(local.tags, {
        Name                = var.gateways_name
        weka_cluster_name   = var.cluster_name
        weka_hostgroup_type = "gateways-protocol"
        protocol            = var.protocol
      })
    }
  }
  user_data = base64encode(local.custom_data)

  lifecycle {
    # Callers that use depends_on on this module (the root module does) defer
    # every data source here to apply time on a fresh deployment. Tie the
    # launch template to the ENA Express support check so an unsupported
    # instance type fails before any gateway is created, not after. A
    # conditional (not ||) is used so the [0] index is never evaluated when
    # disabled on Terraform < 1.12, which does not short-circuit ||.
    precondition {
      condition     = var.ena_express_enabled ? data.aws_ec2_instance_type.ena_express[0].ena_srd_supported : true
      error_message = "ENA Express is enabled but instance type ${var.instance_type} does not support it. See https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ena-express.html#ena-express-supported-instance-types"
    }
  }

  depends_on = [aws_placement_group.this]
}

resource "aws_instance" "this" {
  count = var.protocol == "SMB" || var.protocol == "S3" ? var.gateways_number : 0
  launch_template {
    id = aws_launch_template.this.id
  }

  lifecycle {
    ignore_changes = [tags, launch_template, user_data]
    precondition {
      condition     = var.protocol == "NFS" || var.protocol == "S3" ? var.gateways_number >= 1 : var.gateways_number >= 3 && var.gateways_number <= 8
      error_message = "The amount of protocol gateways should be at least 1 for NFS and at least 3 and at most 8 for SMB."
    }
    precondition {
      condition     = var.protocol == "SMB" && var.setup_protocol ? var.smb_domain_name != "" : true
      error_message = "The SMB domain name should be set when deploying SMB protocol gateways."
    }
    precondition {
      condition     = var.protocol == "SMB" ? var.secondary_ips_per_nic <= 3 : true
      error_message = "The number of secondary IPs per single NIC per protocol gateway virtual machine must be at most 3 for SMB."
    }
  }
  tags       = local.tags
  depends_on = [aws_placement_group.this, aws_iam_instance_profile.this, aws_iam_role.this]
}

resource "aws_autoscaling_group" "autoscaling_group" {
  count                 = var.protocol == "NFS" ? 1 : 0
  name                  = var.gateways_name
  desired_capacity      = var.gateways_number
  max_size              = var.gateways_number
  min_size              = var.gateways_number
  vpc_zone_identifier   = [var.subnet_id]
  suspended_processes   = ["ReplaceUnhealthy"]
  protect_from_scale_in = true

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }
  tag {
    key                 = var.gateways_name
    propagate_at_launch = true
    value               = var.gateways_name
  }
  tag {
    key                 = "Name"
    propagate_at_launch = false
    value               = var.gateways_name
  }

  tag {
    key                 = "weka_cluster_name"
    propagate_at_launch = false
    value               = var.cluster_name
  }

  tag {
    key                 = "weka_hostgroup_type"
    propagate_at_launch = false
    value               = "gateways-protocol"
  }

  dynamic "tag" {
    for_each = local.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false # already propagated by launch template
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity, min_size, max_size]
  }
  depends_on = [aws_launch_template.this]
}
