output "collection_endpoint" {
  value = aws_opensearchserverless_collection.vector_db.collection_endpoint
}

output "collection_arn" {
  value = aws_opensearchserverless_collection.vector_db.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.lambda_repo.repository_url
}