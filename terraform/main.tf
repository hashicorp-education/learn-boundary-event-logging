# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

terraform {
  required_providers {
    boundary  = {
      source  = "hashicorp/boundary"
      version = "1.1.15"
    }
  }
}

provider "boundary" {
  addr             = "http://127.0.0.1:9200"
  recovery_kms_hcl = <<EOT
kms "aead" {
  purpose = "recovery"
  aead_type = "aes-gcm"
  key = "8fZBjCUfN0TzjEGLQldGY4+iE9AkOvCfjh7+p0GtRBQ="
  key_id = "global_recovery"
}
EOT
}

variable "users" {
  type = set(string)
  default = [
    "user1",
  ]
}

resource "boundary_scope" "global" {
  global_scope = true
  name         = "global"
  scope_id     = "global"
}

resource "boundary_scope" "org" {
  scope_id    = boundary_scope.global.id
  name        = "primary"
  description = "Primary organization scope"
}

resource "boundary_scope" "project" {
  name                     = "databases"
  description              = "Databases project"
  scope_id                 = boundary_scope.org.id
  auto_create_admin_role   = true
  auto_create_default_role = true
}

resource "boundary_user" "user" {
  for_each    = var.users
  name        = each.key
  description = "User resource for ${each.key}"
  account_ids = [boundary_account_password.user[each.value].id]
  scope_id    = boundary_scope.org.id
}

resource "boundary_auth_method" "password" {
  name        = "org_password_auth"
  description = "Password auth method for org"
  type        = "password"
  scope_id    = boundary_scope.org.id
}

resource "boundary_account_password" "user" {
  for_each       = var.users
  name           = each.key
  description    = "User account for ${each.key}"
  login_name     = lower(each.key)
  password       = "password"
  auth_method_id = boundary_auth_method.password.id
}

resource "boundary_role" "global_anon_listing" {
  scope_id = boundary_scope.global.id
  principal_ids = ["u_anon"]
  grant_strings = [
    "ids=*;type=auth-method;actions=list,authenticate",
    "type=scope;actions=list",
    "ids={{account.id}};actions=read,change-password"
  ]
}

resource "boundary_role" "org_anon_listing" {
  scope_id      = boundary_scope.org.id
  principal_ids = ["u_anon"]
  grant_strings = [
    "ids=*;type=auth-method;actions=list,authenticate",
    "type=scope;actions=list",
    "ids={{account.id}};actions=read,change-password"
  ]
}
resource "boundary_role" "org_admin" {
  scope_id        = "global"
  grant_scope_ids = [boundary_scope.org.id]
  grant_strings   = ["ids=*;type=*;actions=*"]
  principal_ids = concat(
    [for user in boundary_user.user : user.id],
    ["u_auth"]
  )
}

resource "boundary_role" "proj_admin" {
  scope_id        = boundary_scope.org.id
  grant_scope_ids = [boundary_scope.project.id]
  grant_strings   = ["ids=*;type=*;actions=*"]
  principal_ids = concat(
    [for user in boundary_user.user : user.id],
    ["u_auth"]
  )
}

resource "boundary_host_catalog_static" "databases" {
  name        = "databases"
  description = "Database targets"
  scope_id    = boundary_scope.project.id
}

resource "boundary_host_static" "localhost" {
  type            = "static"
  name            = "localhost"
  description     = "Localhost host"
  address         = "localhost"
  host_catalog_id = boundary_host_catalog_static.databases.id
}

# Target hosts available on localhost: ssh and postgres
# Postgres is exposed to localhost for debugging of the 
# Boundary DB from the CLI. Assumes SSHD is running on
# localhost.
resource "boundary_host_set_static" "local" {
  type            = "static"
  name            = "local"
  description     = "Host set for local servers"
  host_catalog_id = boundary_host_catalog_static.databases.id
  host_ids        = [boundary_host_static.localhost.id]
}

resource "boundary_target" "ssh" {
  type                     = "tcp"
  name                     = "ssh"
  description              = "SSH server"
  scope_id                 = boundary_scope.project.id
  session_connection_limit = -1
  session_max_seconds      = 2
  default_port             = 22
  host_source_ids = [
    boundary_host_set_static.local.id
  ]
}

resource "boundary_target" "db" {
  type                     = "tcp"
  name                     = "boundary-db"
  description              = "Boundary Postgres server"
  scope_id                 = boundary_scope.project.id
  session_connection_limit = -1
  session_max_seconds      = 2
  default_port             = 5432
  host_source_ids = [
    boundary_host_set_static.local.id
  ]
}

resource "boundary_host_static" "postgres" {
  type            = "static"
  name            = "postgres"
  description     = "Private postgres container"
  # DNS set via docker-compose
  address         = "postgres"
  host_catalog_id = boundary_host_catalog_static.databases.id
}

resource "boundary_host_set_static" "postgres" {
  type            = "static"
  name            = "postgres"
  description     = "Host set for postgres containers"
  host_catalog_id = boundary_host_catalog_static.databases.id
  host_ids        = [boundary_host_static.postgres.id]
}

resource "boundary_target" "postgres" {
  type                     = "tcp"
  name                     = "postgres"
  description              = "postgres server"
  scope_id                 = boundary_scope.project.id
  session_connection_limit = -1
  session_max_seconds      = 300
  default_port             = 5432
  host_source_ids = [
    boundary_host_set_static.postgres.id
  ]
}