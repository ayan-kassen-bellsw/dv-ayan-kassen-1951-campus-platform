variable "aws_region" {
  description = "AWS region for the project network."
  type        = string
  default     = "us-east-1"
  nullable    = false
}

variable "resource_prefix" {
  description = "Prefix for resource names and Name tags."
  type        = string
  default     = "dv-ayan-kassen-1951"
  nullable    = false
}

variable "vpc_cidr" {
  description = "IPv4 /16 network from which the public and private /24 subnets are allocated."
  type        = string
  default     = "10.56.0.0/16"
  nullable    = false

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/16") && try(cidrhost(var.vpc_cidr, 0) == split("/", var.vpc_cidr)[0], false)
    error_message = "Use an IPv4 /16 network address with no host bits, for example 10.56.0.0/16."
  }
}
