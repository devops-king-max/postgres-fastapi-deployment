terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial S3 backend: bucket, key, region and lock table are supplied at init
  # time (see backend.hcl.example and the GitHub workflow). The bucket and lock
  # table are created by terraform/bootstrap.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
