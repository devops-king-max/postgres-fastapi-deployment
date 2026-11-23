output "sns_topic_arn" {
  description = "SNS topic that receives every alarm and OK notification."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "Names of the notifying alarms."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.this : a.alarm_name],
    [aws_cloudwatch_metric_alarm.latency_p95.alarm_name],
    aws_cloudwatch_metric_alarm.db_check[*].alarm_name,
  )
}
