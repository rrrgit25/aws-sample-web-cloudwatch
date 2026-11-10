# ---------------------------------------------------------------- general
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project name, used as a prefix for every resource."
  type        = string
  default     = "sample-web"
}

variable "environment" {
  description = "Environment name (dev, staging, prod...)."
  type        = string
  default     = "dev"
}

variable "extra_tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- network
variable "vpc_cidr" {
  description = "CIDR block for the VPC (one public subnet, no NAT gateway)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH (22) and the Kubernetes API (6443). Use your own IP, e.g. [\"203.0.113.10/32\"]."
  type        = list(string)
}

variable "app_ingress_cidrs" {
  description = "CIDRs allowed to reach the web app on port 80."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ----------------------------------------------------------------- server
variable "instance_type" {
  description = "Free-tier eligible instance type. Check yours with: aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query 'InstanceTypes[].InstanceType'"
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size. The free tier covers 30 GB of gp2/gp3 in total."
  type        = number
  default     = 20

  validation {
    condition     = var.root_volume_size_gb <= 30
    error_message = "Keep the root volume at 30 GB or less to stay inside the EBS free tier."
  }
}

variable "swap_size_mb" {
  description = "Swap file size. Gives k3s headroom on a 1 GB instance."
  type        = number
  default     = 1024
}

variable "ssh_public_key_path" {
  description = "Public key installed on the instance for the ec2-user account."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "k3s_channel" {
  description = "k3s release channel (stable, latest, or a minor such as v1.33)."
  type        = string
  default     = "stable"
}

# ------------------------------------------------------------ application
variable "app_namespace" {
  description = "Kubernetes namespace of the Helm release (must match scripts/deploy.sh)."
  type        = string
  default     = "sample-web"
}

variable "app_name" {
  description = "Helm release / Deployment name (must match scripts/deploy.sh)."
  type        = string
  default     = "sample-web"
}

# ------------------------------------------------------------- alarming
variable "alarm_email_endpoints" {
  description = "E-mail addresses for alarm and budget notifications. Each must confirm the SNS subscription e-mail."
  type        = list(string)
  default     = []
}

variable "cpu_threshold_percent" {
  type    = number
  default = 80
}

variable "cpu_credit_balance_threshold" {
  description = "Alarm when the burstable CPU credit balance drops below this (the instance is throttled to baseline at 0)."
  type        = number
  default     = 20
}

variable "memory_threshold_percent" {
  description = "k3s itself uses most of a 1 GB instance, so the default is high."
  type        = number
  default     = 90
}

variable "disk_threshold_percent" {
  type    = number
  default = 80
}

variable "app_error_log_threshold" {
  description = "Alarm when more than this many ERROR/CRITICAL log lines appear in 5 minutes."
  type        = number
  default     = 5
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "monthly_budget_usd" {
  description = "AWS Budget limit. You get an e-mail as soon as actual spend passes 1% of it, i.e. as soon as anything starts costing money."
  type        = string
  default     = "1"
}
