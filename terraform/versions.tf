terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Recommended: keep state remotely. Create the bucket/table first (see
  # docs/DEPLOYMENT.md, step 3) then uncomment and run `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   bucket         = "my-tfstate-bucket"
  #   key            = "sample-web/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}
