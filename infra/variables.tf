variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "github_owner" {
  type    = string
  default = "TanatornMokkhao"
}

variable "hub_repo" {
  type    = string
  default = "ff-poc-hub"
}

# Stage name in this repo => GitHub Environment the deploy job runs in.
variable "stages" {
  type = map(string)
  default = {
    staging = "staging"
    prod    = "production"
  }
}
