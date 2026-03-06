# ==============================================================================
# TFLint Configuration
# ==============================================================================
# TFLint is a Terraform linter that detects errors and enforces best practices
# not covered by `terraform validate`.
#
# Installation:
#   brew install tflint                    # macOS
#   choco install tflint                   # Windows
#   curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
#
# Usage:
#   tflint --init     # Initialize plugins (run first)
#   tflint            # Run linter
#   tflint --fix      # Auto-fix some issues
# ==============================================================================

# ------------------------------------------------------------------------------
# TFLint Core Configuration
# ------------------------------------------------------------------------------
config {
  call_module_type = "local"
  force            = false
}

# ------------------------------------------------------------------------------
# Azure Plugin
# ------------------------------------------------------------------------------
# The Azure plugin provides AzureRM-specific rules that validate:
#   - VM sizes exist
#   - Location names are valid
#   - Resource naming conventions
#   - And many more Azure-specific checks
#
# Full rule list: https://github.com/terraform-linters/tflint-ruleset-azurerm
# ------------------------------------------------------------------------------
plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# ------------------------------------------------------------------------------
# Terraform Plugin (Built-in Rules)
# ------------------------------------------------------------------------------
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# ==============================================================================
# Rule Configurations
# ==============================================================================

# Ensure all variables have descriptions
rule "terraform_documented_variables" {
  enabled = true
}

# Ensure all outputs have descriptions
rule "terraform_documented_outputs" {
  enabled = true
}

# Ensure consistent naming convention (snake_case)
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Warn about deprecated syntax
rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Ensure terraform blocks have required_version
rule "terraform_required_version" {
  enabled = true
}

# Ensure all providers have version constraints
rule "terraform_required_providers" {
  enabled = true
}

# Warn about unused variables
rule "terraform_unused_declarations" {
  enabled = true
}

# Ensure standard module structure
rule "terraform_standard_module_structure" {
  enabled = true
}
