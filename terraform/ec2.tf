data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_key_pair" "admin" {
  key_name   = "${local.name}-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# Created before the instance so its address can be baked into the k3s API
# certificate (--tls-san). Free while attached to a running instance within
# the free tier's 750 public-IPv4 hours.
resource "aws_eip" "server" {
  domain = "vpc"
  tags   = { Name = local.name }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_instance" "server" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.server.id]
  iam_instance_profile   = aws_iam_instance_profile.server.name
  key_name               = aws_key_pair.admin.key_name

  # "standard" credits never bill for CPU bursting ("unlimited" can).
  credit_specification {
    cpu_credits = "standard"
  }

  # Basic (5-minute) monitoring is free; detailed monitoring is not.
  monitoring = false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region            = var.aws_region
    public_ip         = aws_eip.server.public_ip
    k3s_channel       = var.k3s_channel
    swap_size_mb      = var.swap_size_mb
    app_namespace     = var.app_namespace
    app_name          = var.app_name
    ecr_registry      = split("/", aws_ecr_repository.app.repository_url)[0]
    log_group_name    = aws_cloudwatch_log_group.app.name
    metrics_namespace = local.metrics_namespace
  })
  user_data_replace_on_change = true

  tags = { Name = local.name }

  lifecycle {
    ignore_changes = [ami] # don't rebuild the server every time AL2023 is patched
  }
}

resource "aws_eip_association" "server" {
  instance_id   = aws_instance.server.id
  allocation_id = aws_eip.server.id
}
