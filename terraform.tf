terraform {
  required_version = ">=1.4.6"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">=2.39.0"
    }
    msgraph = {
      source  = "microsoft/msgraph"
      version = ">=0.3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">=3.0.0"
    }
  }
}
