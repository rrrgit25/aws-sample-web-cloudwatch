data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "server" {
  name               = "${local.name}-server"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "server" {
  for_each = toset([
    # CloudWatch agent: metrics, logs, PutMetricData for the app monitor script
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
    # Pull the app image from ECR
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Optional shell access through Systems Manager Session Manager (free)
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.server.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "server" {
  name = "${local.name}-server"
  role = aws_iam_role.server.name
}
