# Optional least-privilege IAM user for Jenkins to push images to ECR.
# Off by default; enable with create_ci_user = true. Create its access key in
# the IAM console afterwards (so the secret never lands in Terraform state) and
# store it in Jenkins as the "aws-ecr-push" AWS credential.

variable "create_ci_user" {
  description = "Create an IAM user that Jenkins uses to push images to ECR."
  type        = bool
  default     = false
}

data "aws_iam_policy_document" "ci_ecr_push" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPullThisRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_user" "ci" {
  count = var.create_ci_user ? 1 : 0
  name  = "${local.name}-jenkins"
}

resource "aws_iam_user_policy" "ci_ecr_push" {
  count  = var.create_ci_user ? 1 : 0
  name   = "ecr-push-${var.project_name}"
  user   = aws_iam_user.ci[0].name
  policy = data.aws_iam_policy_document.ci_ecr_push.json
}

output "ci_user_name" {
  description = "IAM user for Jenkins (create an access key for it in the IAM console)."
  value       = var.create_ci_user ? aws_iam_user.ci[0].name : null
}
