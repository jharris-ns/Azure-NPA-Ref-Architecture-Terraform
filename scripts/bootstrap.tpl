#!/bin/bash
set -e

# Install curl (not included in the Netskope NPA publisher image)
sudo apt-get update -qq && sudo apt-get install -y -qq curl > /dev/null

# Fetch access token from IMDS using the VM's managed identity
access_token=$(curl -s -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | jq -r '.access_token')

# Retrieve the publisher token from Key Vault
token=$(curl -s -H "Authorization: Bearer $access_token" \
  "https://${vault_name}.vault.azure.net/secrets/${secret_name}?api-version=7.4" \
  | jq -r '.value')

# Register the publisher
sudo /home/ubuntu/npa_publisher_wizard -token "$token"

# Clear sensitive variables
unset access_token token
