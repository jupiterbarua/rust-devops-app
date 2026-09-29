resource "aws_ecr_repository" "app" {
  name                 = "rust-devops-app"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

import {
  to = aws_ecr_repository.app
  id = "rust-devops-app"
}