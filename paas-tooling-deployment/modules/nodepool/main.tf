locals {}

# resource "aws_security_group" "this" {
#   name        = "${var.name}-rke2-nodepool"
#   vpc_id      = var.vpc_id
#   description = "${var.name} node pool"
#   tags        = merge({}, var.tags)
# }

#
# Launch template
#
resource "aws_launch_template" "this" {
  name                   = "${var.name}-rke2-nodepool"
  image_id               = var.ami
  instance_type          = var.instance_type
  user_data              = var.userdata
  vpc_security_group_ids = concat(var.vpc_security_group_ids)
  key_name               = "paas-tooling20200916193158260600000001"
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = lookup(var.block_device_mappings, "type", null)
      volume_size           = lookup(var.block_device_mappings, "size", null)
      iops                  = lookup(var.block_device_mappings, "iops", null)
      kms_key_id            = lookup(var.block_device_mappings, "kms_key_id", null)
      encrypted             = true
      delete_on_termination = lookup(var.block_device_mappings, "delete_on_termination", null)
    }
  }

  iam_instance_profile {
    name = var.iam_instance_profile
  }

  tags = merge({}, var.tags)
}

#
# Autoscaling group
#
resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-rke2-nodepool"
  vpc_zone_identifier = var.subnets

  min_size         = var.asg.min
  max_size         = var.asg.max
  desired_capacity = var.asg.desired

  # Health check and target groups dependent on whether we're a server or not (identified via rke2_url)
  health_check_type = var.health_check_type
  target_group_arns = var.target_group_arns
  load_balancers    = var.load_balancers

  min_elb_capacity = var.min_elb_capacity

  dynamic "launch_template" {
    for_each = var.spot ? [] : ["spot"]

    content {
      id      = aws_launch_template.this.id
      version = "$Latest"
    }
  }

  dynamic "mixed_instances_policy" {
    for_each = var.spot ? ["spot"] : []

    content {
      instances_distribution {
        on_demand_base_capacity                  = 0
        on_demand_percentage_above_base_capacity = 0
      }

      launch_template {
        launch_template_specification {
          launch_template_id   = aws_launch_template.this.id
          launch_template_name = aws_launch_template.this.name
          version              = "$Latest"
        }
      }
    }
  }

  dynamic "tag" {
    for_each = merge({
      "Name" = "${var.name}-rke2-nodepool"
    }, var.tags)

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [load_balancers, target_group_arns]
  }
}
