terraform {
  # 1.7+ is needed for `terraform test` with mock providers.
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80.0, < 6.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0, < 4.0.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.0, < 4.0.0"
    }
  }

  # Local state by default (one-day demo). To share state, copy
  # backend.tf.example to backend.tf and run `terraform init -migrate-state`.
}
