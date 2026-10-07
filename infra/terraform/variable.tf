variable "github_owner" {
  type        = string
  description = "Owners of the repo"
  default     = "jupiterbarua"
}

variable "github_repo" {
  type        = string
  description = "Github repository name"
  default     = "rust-devops-app"
}

variable "github_owner_id" {
  type        = string
  description = "Numeric github repository ID"
}

variable "github_repo_id" {
  type        = string
  description = "Numeric GitHub repository ID"
}

variable "alert_email" {
  type        = string
  description = "Email address for AWS budget alerts"
}

variable "my_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR form, e.g. 203.0.113.10/32"
}

variable "k3s_instance_type" {
  type        = string
  description = "EC2 instance type for the k3s node"
  default     = "t3.small"
}