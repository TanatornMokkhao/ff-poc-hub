terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # A real setup keeps state in S3 with locking, e.g.:
  # backend "s3" {
  #   bucket       = "ff-poc-terraform-state"
  #   key          = "hub/terraform.tfstate"
  #   region       = "ap-southeast-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region
}
