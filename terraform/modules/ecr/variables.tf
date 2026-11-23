variable "name" {
  description = "ECR repository name."
  type        = string
}

variable "image_tag_mutability" {
  description = "MUTABLE allows re-pushing a tag such as latest; IMMUTABLE forces unique tags (recommended once CI pushes git-SHA tags)."
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "keep_last_images" {
  description = "Number of images to retain."
  type        = number
  default     = 10
}

variable "force_delete" {
  description = "Delete the repository even if it still contains images."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
