
variable "confluent_cloud_api_key" {
  description = "Confluent Cloud API Key (also referred as Cloud API ID)"
  type        = string
}

variable "confluent_cloud_api_secret" {
  description = "Confluent Cloud API Secret"
  type        = string
  sensitive   = true
}

variable "confluent_cloud_account" {
  description = "Confluent Cloud account ID to create resources under"
  type        = string
}

variable "use_prefix" {
  description = "choose a prefix to all your resources"
  type        = string
}


variable "email" {
  description = "Your email to tag all AWS resources"
  type        = string
}

variable "cloud_region"{
  description = "AWS Cloud Region"
  type        = string
  default     = "us-east-1"    
}

variable "db_username"{
  description = "Postgres DB username"
  type        = string
  default     = "postgres"  
}

variable "db_password"{
  description = "Postgres DB password"
  type        = string
}