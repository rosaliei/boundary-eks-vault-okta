output "asg_name" {
  value = aws_autoscaling_group.worker.name
}

output "worker_iam_role_arn" {
  description = "Must equal ../brokers output trusted_iam_role_arn"
  value       = aws_iam_role.worker.arn
}

output "launch_template_id" {
  value = aws_launch_template.worker.id
}

output "scale_command" {
  description = "What scale.yml runs (for a manual test)"
  value       = "aws autoscaling set-desired-capacity --auto-scaling-group-name ${aws_autoscaling_group.worker.name} --desired-capacity <n> --profile ${var.aws_profile}"
}
