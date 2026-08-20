output "alb_id" {
  description = "ID of the Application Load Balancer"
  value       = aws_lb.main.id
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the Application Load Balancer"
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "ARN of the target group"
  value       = aws_lb_target_group.main.arn
}

output "target_group_name" {
  description = "Name of the target group"
  value       = aws_lb_target_group.main.name
}

output "alb_arn_suffix" {
  description = "ARN suffix of the Application Load Balancer for CloudWatch dimensions"
  value       = aws_lb.main.arn_suffix
}

output "target_group_arn_suffix" {
  description = "ARN suffix of the target group for CloudWatch dimensions"
  value       = aws_lb_target_group.main.arn_suffix
}

output "http_listener_arn" {
  description = "ARN of the HTTP listener"
  value       = try(aws_lb_listener.http_redirect[0].arn, aws_lb_listener.http_forward[0].arn)
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener (if configured)"
  value       = try(aws_lb_listener.https[0].arn, "")

}
