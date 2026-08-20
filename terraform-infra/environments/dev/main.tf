# Get current AWS account ID and region
data "aws_caller_identity" "current" {}


locals {
  dns_enabled        = var.hosted_zone_name != "" && var.app_domain_name != ""
  cloudtrail_enabled = var.terraform_state_bucket_name != ""
  alarm_actions      = var.alarm_notification_email != "" ? [aws_sns_topic.alerts[0].arn] : []
}

data "aws_route53_zone" "public" {
  count        = local.dns_enabled ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}

# Generate random password for database
resource "random_password" "db_password" {
  length  = 16
  special = true
  # Exclude characters that might cause issues in connection strings
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# VPC Module
module "vpc" {
  source = "../../modules/vpc"

  environment           = var.environment
  project               = var.project
  vpc_cidr              = var.vpc_cidr
  availability_zones    = var.availability_zones
  public_subnet_cidrs   = var.public_subnet_cidrs
  frontend_subnet_cidrs = var.frontend_subnet_cidrs
  backend_subnet_cidrs  = var.backend_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs
  enable_nat_gateway    = true
  single_nat_gateway    = var.single_nat_gateway

  tags = var.tags
}

# Security Groups Module
module "security_groups" {
  source = "../../modules/security-groups"

  environment       = var.environment
  project           = var.project
  vpc_id            = module.vpc.vpc_id
  allowed_ssh_cidrs = [var.allowed_ssh_cidr]
  enable_bastion    = var.enable_bastion

  tags = var.tags
}

# IAM Module
module "iam" {
  source = "../../modules/iam"

  environment  = var.environment
  project      = var.project
  secrets_arns = [module.secrets.db_secret_arn] # Will be updated after secrets are created

  tags = var.tags
}

# RDS Module
module "rds" {
  source = "../../modules/rds"

  environment             = var.environment
  project                 = var.project
  subnet_ids              = module.vpc.database_subnet_ids
  security_group_id       = module.security_groups.rds_sg_id
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  engine_version          = var.db_engine_version
  db_name                 = var.db_name
  db_username             = var.db_username
  db_password             = random_password.db_password.result
  multi_az                = var.db_multi_az
  backup_retention_period = var.db_backup_retention
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.db_skip_final_snapshot

  tags = var.tags
}

# Secrets Manager Module
module "secrets" {
  source = "../../modules/secrets"

  environment = var.environment
  project     = var.project
  db_username = var.db_username
  db_password = random_password.db_password.result
  db_host     = module.rds.db_address
  db_port     = module.rds.db_port
  db_name     = var.db_name

  tags = var.tags
}

# Bastion Module
module "bastion" {
  source = "../../modules/bastion"

  enable_bastion       = var.enable_bastion
  environment          = var.environment
  project              = var.project
  instance_type        = var.bastion_instance_type
  key_name             = var.ssh_key_name
  subnet_id            = module.vpc.public_subnet_ids[0]
  security_group_id    = module.security_groups.bastion_sg_id
  iam_instance_profile = module.iam.ec2_instance_profile_name

  tags = var.tags
}

# Public Application Load Balancer Module (Frontend)
module "alb" {
  source = "../../modules/alb"

  environment       = var.environment
  project           = var.project
  name_prefix       = "public-"
  internal          = false
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.security_groups.alb_sg_id
  target_group_port = 3000
  enable_https      = true

  certificate_arn = aws_acm_certificate.app[0].arn

  depends_on = [
    aws_acm_certificate_validation.app
  ]


  tags = var.tags
}

# Internal Application Load Balancer Module (Backend)
module "internal_alb" {
  source = "../../modules/alb"

  environment       = var.environment
  project           = var.project
  name_prefix       = "internal-"
  internal          = true
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.frontend_subnet_ids # Note: Using Frontend subnets for reachability
  security_group_id = module.security_groups.internal_alb_sg_id
  target_group_port = 8080

  tags = var.tags
}

# Frontend ASG Module
module "frontend_asg" {
  source = "../../modules/frontend-asg"

  environment          = var.environment
  project              = var.project
  region               = var.region
  instance_type        = var.frontend_instance_type
  key_name             = var.enable_bastion ? var.ssh_key_name : null
  iam_instance_profile = module.iam.ec2_instance_profile_name
  security_group_id    = module.security_groups.frontend_sg_id
  subnet_ids           = module.vpc.frontend_subnet_ids
  target_group_arn     = module.alb.target_group_arn
  min_size             = var.frontend_min_size
  max_size             = var.frontend_max_size
  desired_capacity     = var.frontend_desired_capacity
  alarm_actions        = local.alarm_actions

  docker_image         = var.frontend_docker_image
  dockerhub_username   = var.dockerhub_username
  dockerhub_password   = var.dockerhub_password
  backend_internal_url = "http://${module.internal_alb.alb_dns_name}"

  tags = var.tags

  depends_on = [module.rds, module.alb, module.internal_alb]
}

# Backend ASG Module
module "backend_asg" {
  source = "../../modules/backend-asg"

  environment          = var.environment
  project              = var.project
  region               = var.region
  instance_type        = var.backend_instance_type
  key_name             = var.enable_bastion ? var.ssh_key_name : null
  iam_instance_profile = module.iam.ec2_instance_profile_name
  security_group_id    = module.security_groups.backend_sg_id
  subnet_ids           = module.vpc.backend_subnet_ids
  target_group_arns    = [module.internal_alb.target_group_arn]
  min_size             = var.backend_min_size
  max_size             = var.backend_max_size
  desired_capacity     = var.backend_desired_capacity
  alarm_actions        = local.alarm_actions

  docker_image       = var.backend_docker_image
  dockerhub_username = var.dockerhub_username
  dockerhub_password = var.dockerhub_password
  db_secret_arn      = module.secrets.db_secret_arn

  tags = var.tags

  depends_on = [module.rds, module.secrets]
}

resource "aws_acm_certificate" "app" {
  count             = local.dns_enabled ? 1 : 0
  domain_name       = var.app_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.environment}-${var.project}-app-cert"
  })
}

resource "aws_route53_record" "app_cert_validation" {
  for_each = local.dns_enabled ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.public[0].zone_id
}

resource "aws_acm_certificate_validation" "app" {
  count                   = local.dns_enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for record in aws_route53_record.app_cert_validation : record.fqdn]
}

resource "aws_route53_record" "app" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = var.app_domain_name
  type    = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_wafv2_web_acl" "alb" {
  name        = "${var.environment}-${var.project}-alb-waf"
  description = "Basic AWS managed WAF rules for the public ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.environment}-${var.project}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.environment}-${var.project}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.environment}-${var.project}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = module.alb.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

resource "aws_kms_key" "sns" {
  description         = "KMS key for SNS alerts"
  enable_key_rotation = true

  tags = var.tags
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${var.environment}-${var.project}-sns"
  target_key_id = aws_kms_key.sns.key_id
}


resource "aws_sns_topic" "alerts" {
  count = var.alarm_notification_email != "" ? 1 : 0
  name  = "${var.environment}-${var.project}-alerts"

  kms_master_key_id = aws_kms_key.sns.arn

  tags = var.tags
}


resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alarm_notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alarm_notification_email
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.environment}-${var.project}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "External ALB is returning elevated 5xx responses"
  alarm_actions       = local.alarm_actions

  dimensions = {
    LoadBalancer = module.alb.alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_high_latency" {
  alarm_name          = "${var.environment}-${var.project}-alb-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 2
  alarm_description   = "External ALB target response time is above 2 seconds"
  alarm_actions       = local.alarm_actions

  dimensions = {
    LoadBalancer = module.alb.alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "frontend_unhealthy_targets" {
  alarm_name          = "${var.environment}-${var.project}-frontend-targets-unhealthy"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "External ALB has unhealthy frontend targets"
  alarm_actions       = local.alarm_actions

  dimensions = {
    LoadBalancer = module.alb.alb_arn_suffix
    TargetGroup  = module.alb.target_group_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "backend_unhealthy_targets" {
  alarm_name          = "${var.environment}-${var.project}-backend-targets-unhealthy"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "Internal ALB has unhealthy backend targets"
  alarm_actions       = local.alarm_actions

  dimensions = {
    LoadBalancer = module.internal_alb.alb_arn_suffix
    TargetGroup  = module.internal_alb.target_group_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "frontend_status_check_failed" {
  alarm_name          = "${var.environment}-${var.project}-frontend-status-check-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Frontend EC2 status checks are failing"
  alarm_actions       = local.alarm_actions

  dimensions = {
    AutoScalingGroupName = module.frontend_asg.asg_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "backend_status_check_failed" {
  alarm_name          = "${var.environment}-${var.project}-backend-status-check-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Backend EC2 status checks are failing"
  alarm_actions       = local.alarm_actions

  dimensions = {
    AutoScalingGroupName = module.backend_asg.asg_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_high_cpu" {
  alarm_name          = "${var.environment}-${var.project}-rds-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU utilization is high"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = module.rds.db_instance_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name          = "${var.environment}-${var.project}-rds-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2147483648
  alarm_description   = "RDS free storage is below 2 GiB"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = module.rds.db_instance_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_high_connections" {
  alarm_name          = "${var.environment}-${var.project}-rds-high-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS database connections are high"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = module.rds.db_instance_id
  }

  tags = var.tags
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  count = local.cloudtrail_enabled ? 1 : 0

  statement {
    sid     = "AWSCloudTrailAclCheck"
    actions = ["s3:GetBucketAcl"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    resources = ["arn:aws:s3:::${var.terraform_state_bucket_name}"]
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    actions = ["s3:PutObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    resources = ["arn:aws:s3:::${var.terraform_state_bucket_name}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = local.cloudtrail_enabled ? 1 : 0
  bucket = var.terraform_state_bucket_name
  policy = data.aws_iam_policy_document.cloudtrail_bucket[0].json
}

resource "aws_kms_key" "cloudtrail" {
  count                   = local.cloudtrail_enabled ? 1 : 0
  description             = "KMS key for CloudTrail logs"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudTrail to encrypt logs"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "cloudtrail" {
  count         = local.cloudtrail_enabled ? 1 : 0
  name          = "alias/${var.environment}-${var.project}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail[0].key_id
}


resource "aws_cloudtrail" "main" {
  count                         = local.cloudtrail_enabled ? 1 : 0
  name                          = "${var.environment}-${var.project}-trail"
  s3_bucket_name                = var.terraform_state_bucket_name
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  enable_log_file_validation = true

  kms_key_id = aws_kms_key.cloudtrail[0].arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = var.tags

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_kms_key.cloudtrail
  ]
}
