#############################################################################
# CloudWatch, sized for the free tier:
#   - 9 standard-resolution alarms          (free tier: 10)
#   - 6 custom metrics                      (free tier: 10)
#       CWAgent: mem_used_percent, disk_used_percent
#       app monitor: HealthCheck, ReadyPods, ContainerRestarts
#       log metric filter: ApplicationErrorCount
#   - 1 dashboard                           (free tier: 3)
#   - Logs, 7-day retention, low volume     (free tier: 5 GB)
#   - EC2 basic monitoring metrics          (always free)
#   - SNS e-mail notifications              (free tier: 1,000 / month)
# No composite alarms, no detailed monitoring, no Container Insights.
#############################################################################

resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_email_endpoints)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  alarm_actions = [aws_sns_topic.alarms.arn]
  instance_dims = { InstanceId = aws_instance.server.id }
}

#############################################################################
# Instance alarms (AWS/EC2 basic monitoring - free metrics)
#############################################################################

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.name}-cpu-high"
  alarm_description   = "Instance CPU above ${var.cpu_threshold_percent}% for 10 minutes."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = local.instance_dims
  statistic           = "Average"
  period              = 300 # basic monitoring resolution
  evaluation_periods  = 2
  threshold           = var.cpu_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "cpu_credits_low" {
  alarm_name          = "${local.name}-cpu-credits-low"
  alarm_description   = "CPU credit balance below ${var.cpu_credit_balance_threshold}; at 0 the instance is throttled to its baseline."
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  dimensions          = local.instance_dims
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.cpu_credit_balance_threshold
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "status_check_system" {
  alarm_name          = "${local.name}-status-check-system"
  alarm_description   = "AWS hardware/host problem. The instance is automatically recovered onto healthy hardware."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = local.instance_dims
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = concat(local.alarm_actions, ["arn:aws:automate:${var.aws_region}:ec2:recover"])
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "status_check_instance" {
  alarm_name          = "${local.name}-status-check-instance"
  alarm_description   = "The OS is unreachable (kernel panic, out of memory...). The instance is automatically rebooted."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = local.instance_dims
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = concat(local.alarm_actions, ["arn:aws:automate:${var.aws_region}:ec2:reboot"])
  ok_actions          = local.alarm_actions
}

#############################################################################
# OS alarms (CloudWatch agent - 2 custom metrics)
#############################################################################

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${local.name}-memory-high"
  alarm_description   = "Memory used above ${var.memory_threshold_percent}% for 5 minutes."
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  dimensions          = local.instance_dims
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 4
  threshold           = var.memory_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name        = "${local.name}-disk-high"
  alarm_description = "Root filesystem above ${var.disk_threshold_percent}% used."
  namespace         = "CWAgent"
  metric_name       = "disk_used_percent"
  dimensions = {
    InstanceId = aws_instance.server.id
    path       = "/"
    fstype     = "xfs" # Amazon Linux 2023 root filesystem
  }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.disk_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

#############################################################################
# Application alarms (custom metrics from the on-instance app monitor)
#############################################################################

resource "aws_cloudwatch_metric_alarm" "app_health_failed" {
  alarm_name          = "${local.name}-app-health-failed"
  alarm_description   = "GET /health/ready on port 80 is failing - the web app is down."
  namespace           = local.metrics_namespace
  metric_name         = "HealthCheck"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # No data means the instance or the monitor itself is down: treat as an outage.
  treat_missing_data = "breaching"
  alarm_actions      = local.alarm_actions
  ok_actions         = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "app_container_restarts" {
  alarm_name          = "${local.name}-app-container-restarts"
  alarm_description   = "Containers of ${var.app_name} restarted (crash, OOM kill or failed liveness probe)."
  namespace           = local.metrics_namespace
  metric_name         = "ContainerRestarts"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

#############################################################################
# Application error logs -> metric filter -> alarm
#############################################################################

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/${var.environment}/app"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${local.name}-app-errors"
  log_group_name = aws_cloudwatch_log_group.app.name

  # Matches the app's JSON level field and gunicorn's own [ERROR]/[CRITICAL] lines.
  # Terms are case-sensitive, so ordinary lowercase "error" text is not counted.
  pattern = "?ERROR ?CRITICAL"

  metric_transformation {
    name          = "ApplicationErrorCount"
    namespace     = local.metrics_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_error_logs" {
  alarm_name          = "${local.name}-app-error-logs"
  alarm_description   = "More than ${var.app_error_log_threshold} ERROR/CRITICAL log lines from ${var.app_name} in 5 minutes."
  namespace           = local.metrics_namespace
  metric_name         = "ApplicationErrorCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.app_error_log_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  depends_on = [aws_cloudwatch_log_metric_filter.app_errors]
}

#############################################################################
# Dashboard (1 of the 3 free dashboards)
#############################################################################

locals {
  all_alarm_arns = [
    aws_cloudwatch_metric_alarm.app_health_failed.arn,
    aws_cloudwatch_metric_alarm.app_container_restarts.arn,
    aws_cloudwatch_metric_alarm.app_error_logs.arn,
    aws_cloudwatch_metric_alarm.cpu_high.arn,
    aws_cloudwatch_metric_alarm.cpu_credits_low.arn,
    aws_cloudwatch_metric_alarm.memory_high.arn,
    aws_cloudwatch_metric_alarm.disk_high.arn,
    aws_cloudwatch_metric_alarm.status_check_system.arn,
    aws_cloudwatch_metric_alarm.status_check_instance.arn,
  ]
}

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = local.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "alarm", x = 0, y = 0, width = 24, height = 4
        properties = { title = "Alarms", alarms = local.all_alarm_arns }
      },
      {
        type = "metric", x = 0, y = 4, width = 12, height = 6
        properties = {
          title  = "App health / ready pods / restarts"
          region = var.aws_region
          period = 60
          metrics = [
            [local.metrics_namespace, "HealthCheck", { stat = "Minimum" }],
            [local.metrics_namespace, "ReadyPods", { stat = "Minimum" }],
            [local.metrics_namespace, "ContainerRestarts", { stat = "Sum" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 4, width = 12, height = 6
        properties = {
          title   = "Application errors (log lines / 5 min)"
          region  = var.aws_region
          stat    = "Sum"
          period  = 300
          metrics = [[local.metrics_namespace, "ApplicationErrorCount"]]
        }
      },
      {
        type = "metric", x = 0, y = 10, width = 12, height = 6
        properties = {
          title  = "CPU % and credit balance"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.server.id],
            ["AWS/EC2", "CPUCreditBalance", "InstanceId", aws_instance.server.id, { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 10, width = 12, height = 6
        properties = {
          title  = "Memory / disk used %"
          region = var.aws_region
          stat   = "Average"
          period = 60
          metrics = [
            ["CWAgent", "mem_used_percent", "InstanceId", aws_instance.server.id],
            ["CWAgent", "disk_used_percent", "InstanceId", aws_instance.server.id, "path", "/", "fstype", "xfs"],
          ]
        }
      },
    ]
  })
}
