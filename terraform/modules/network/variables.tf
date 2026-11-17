variable "project_id" {
  type = string
}

variable "name" {
  description = "Name prefix for the VPC, subnet, router, and NAT."
  type        = string
}

variable "region" {
  type = string
}

variable "nodes_cidr" {
  description = "Primary subnet range. Nodes and internal load balancers use it."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary range for Pods (VPC-native)."
  type        = string
}

variable "services_cidr" {
  description = "Secondary range for ClusterIP Services."
  type        = string
}
