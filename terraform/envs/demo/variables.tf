variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "australia-southeast1"
}

variable "zones" {
  type    = list(string)
  default = ["australia-southeast1-a", "australia-southeast1-b"]
}

variable "name" {
  description = "Name prefix for the environment."
  type        = string
  default     = "demo"
}
