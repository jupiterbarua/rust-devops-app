terraform {
  backend "s3" {
    bucket       = "jupiterbarua-rust-devops-tfstate"
    key          = "rust-devops-app/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}