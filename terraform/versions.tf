terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state for now. For team use, switch to an S3 backend with a lock table.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
