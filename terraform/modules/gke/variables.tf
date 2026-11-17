variable "project_id" {
  type = string
}

variable "name" {
  description = "Cluster name."
  type        = string
}

variable "region" {
  type = string
}

variable "zones" {
  description = "Zones for nodes. The control plane is regional."
  type        = list(string)
}

variable "network_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "pods_range_name" {
  type = string
}

variable "services_range_name" {
  type = string
}

variable "release_channel" {
  description = "GKE release channel. Google upgrades the cluster inside this channel."
  type        = string
  default     = "STABLE"
}

variable "system_pool" {
  description = "On-demand node pool for platform components. Application nodes are created by ComputeClass."
  type = object({
    machine_type = optional(string, "e2-standard-2")
    min_per_zone = optional(number, 1)
    max_per_zone = optional(number, 2)
  })
  default = {}
}

variable "batch_spot_pool" {
  description = "Spot node pool for interruptible batch jobs. Tainted `dedicated=batch:NoSchedule`."
  type = object({
    machine_type = optional(string, "e2-standard-2")
    max_per_zone = optional(number, 2)
  })
  default = {}
}

variable "deletion_protection" {
  description = "Set to true in production."
  type        = bool
  default     = false
}
