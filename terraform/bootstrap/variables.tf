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

variable "github_owner_id" {
  description = "Numeric GitHub ID of the owner (gh api repos/OWNER/REPO -q .owner.id)."
  type        = string
  default     = "169896095"
}

variable "github_repo_id" {
  description = "Numeric GitHub ID of the repository (gh api repos/OWNER/REPO -q .id)."
  type        = string
  default     = "1468483451"
}

variable "deploy_environment" {
  description = "GitHub environment whose jobs may assume the apply role. Limit its deployment branches to main in the repository settings."
  type        = string
  default     = "production"
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
