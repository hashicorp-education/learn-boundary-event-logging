# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "username" {
  sensitive = true
  value = boundary_account_password.user
}