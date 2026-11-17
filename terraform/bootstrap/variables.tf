variable "project_id" {
  description = "Project that holds the demo platform."
  type        = string
}

variable "region" {
  description = "Default region."
  type        = string
  default     = "australia-southeast1"
}

variable "github_repo" {
  description = "GitHub repository (owner/name) that may run Terraform through Workload Identity Federation."
  type        = string
}
