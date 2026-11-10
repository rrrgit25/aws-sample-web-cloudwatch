output "aws_region" {
  value = var.aws_region
}

output "instance_id" {
  value = aws_instance.server.id
}

output "public_ip" {
  description = "Elastic IP of the k3s server."
  value       = aws_eip.server.public_ip
}

output "app_url" {
  value = "http://${aws_eip.server.public_ip}/"
}

output "ssh_command" {
  value = "ssh ec2-user@${aws_eip.server.public_ip}"
}

output "ecr_repository_url" {
  description = "Push the application image here."
  value       = aws_ecr_repository.app.repository_url
}

output "sns_topic_arn" {
  description = "SNS topic that receives every alarm notification."
  value       = aws_sns_topic.alarms.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "cloudwatch_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.app.dashboard_name}"
}

output "alarm_name_prefix" {
  value = "${local.name}-"
}
