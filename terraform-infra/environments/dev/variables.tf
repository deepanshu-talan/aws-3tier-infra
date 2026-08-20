# General
variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}


variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "goal-tracker"
}

# Network
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "frontend_subnet_cidrs" {
  description = "CIDR blocks for frontend subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "backend_subnet_cidrs" {
  description = "CIDR blocks for backend subnets"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for database subnets"
  type        = list(string)
  default     = ["10.0.31.0/24", "10.0.32.0/24"]
}

variable "single_nat_gateway" {
  description = "Use single NAT Gateway to save costs"
  type        = bool
  default     = true
}

# SSH
variable "ssh_key_name" {
  description = "SSH key pair name for EC2 instances when bastion is enabled"
  type        = string
  default     = null
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH to bastion (your IP)"
  type        = string
  default     = "0.0.0.0/0"
}

# Bastion
variable "bastion_instance_type" {
  description = "Bastion instance type"
  type        = string
  default     = "t2.micro"
}

variable "enable_bastion" {
  description = "Create the bastion host and SSH security group rules"
  type        = bool
  default     = false
}

# Frontend ASG
variable "frontend_instance_type" {
  description = "Frontend instance type"
  type        = string
  default     = "t3.micro"
}

variable "frontend_min_size" {
  description = "Frontend ASG minimum size"
  type        = number
  default     = 2
}

variable "frontend_max_size" {
  description = "Frontend ASG maximum size"
  type        = number
  default     = 4
}

variable "frontend_desired_capacity" {
  description = "Frontend ASG desired capacity"
  type        = number
  default     = 2
}

# Backend ASG
variable "backend_instance_type" {
  description = "Backend instance type"
  type        = string
  default     = "t3.micro"
}

variable "backend_min_size" {
  description = "Backend ASG minimum size"
  type        = number
  default     = 2
}

variable "backend_max_size" {
  description = "Backend ASG maximum size"
  type        = number
  default     = 6
}

variable "backend_desired_capacity" {
  description = "Backend ASG desired capacity"
  type        = number
  default     = 2
}

# RDS
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "17"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "goalsdb"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "postgres"
}

variable "db_multi_az" {
  description = "Enable RDS Multi-AZ"
  type        = bool
  default     = true
}

# DNS / HTTPS
variable "hosted_zone_name" {
  description = "Existing Route 53 public hosted zone name, for example example.com"
  type        = string
  default     = ""
}

variable "app_domain_name" {
  description = "Application DNS name to point at the public ALB, for example goals.example.com"
  type        = string
  default     = ""
}

# Remote state / audit logs
variable "terraform_state_bucket_name" {
  description = "Existing S3 bucket used for Terraform remote state and basic CloudTrail logs"
  type        = string
  default     = ""
}

# Alerting
variable "alarm_notification_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
  default     = ""
}

variable "db_backup_retention" {
  description = "RDS backup retention period in days"
  type        = number
  default     = 0
}

variable "deletion_protection" {
  description = "Enable deletion protection for RDS instance"
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip final snapshot on destroy"
  type        = bool
  default     = true
}

# Docker Hub
variable "frontend_docker_image" {
  description = "Frontend Docker image (e.g., username/frontend:<git-sha>)"
  type        = string
  default     = "your-dockerhub-username/goal-tracker-frontend:git-sha"
}

variable "backend_docker_image" {
  description = "Backend Docker image (e.g., username/backend:<git-sha>)"
  type        = string
  default     = "your-dockerhub-username/goal-tracker-backend:git-sha"
}

variable "dockerhub_username" {
  description = "Docker Hub username (leave empty for public images)"
  type        = string
  default     = ""
}

variable "dockerhub_password" {
  description = "Docker Hub password or access token (leave empty for public images)"
  type        = string
  default     = ""
  sensitive   = true
}

# Tags
variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Environment = "dev"
    Project     = "goal-tracker"
    ManagedBy   = "terraform"
  }
}
