variable "aws_region" {
  description = "Region for the state bucket and lock table."
  type        = string
  default     = "us-east-1"
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
  default     = "devops-king-max"
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
  default     = "postgres-fastapi-deployment"
}

variable "deploy_branch" {
  description = "Only this branch may assume the apply role."
  type        = string
  default     = "main"
}

variable "app_name" {
  description = "Must equal the root module's var.name; scopes the apply role's IAM rights."
  type        = string
  default     = "fastapi-postgres"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
}
