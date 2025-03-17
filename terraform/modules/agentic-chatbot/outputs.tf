output "chatbot_role_arn" {
  value = module.irsa_role.iam_role_arn
}

output "chatbot_ecr_repo" {
  value = aws_ecr_repository.chatbot_repo.repository_url
}

