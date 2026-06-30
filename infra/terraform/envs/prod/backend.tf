terraform {
  backend "gcs" {
    bucket = "arkmask-tfstate"
    prefix = "arkmask/prod"
  }
}
