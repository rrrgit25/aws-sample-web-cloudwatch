provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

# Pick an AZ where the chosen (free-tier) instance type is actually offered.
data "aws_ec2_instance_type_offerings" "available" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

locals {
  name = "${var.project_name}-${var.environment}"
  az   = sort(data.aws_ec2_instance_type_offerings.available.locations)[0]

  # Namespace for the custom metrics published from the instance.
  metrics_namespace = "${var.project_name}/${var.environment}"

  tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.extra_tags,
  )
}
