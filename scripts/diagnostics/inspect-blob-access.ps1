#!/usr/bin/env pwsh
$sa = az storage account show --name stdemofsdemo --resource-group rg-demofs-foundry -o json | ConvertFrom-Json
Write-Host "publicNetworkAccess:          $($sa.publicNetworkAccess)"
Write-Host "allowBlobPublicAccess:        $($sa.allowBlobPublicAccess)"
Write-Host "networkRuleSet.defaultAction: $($sa.networkRuleSet.defaultAction)"
Write-Host "allowSharedKeyAccess:         $($sa.allowSharedKeyAccess)"
Write-Host "`n=== container public access ==="
az storage container show --account-name stdemofsdemo --name knowledge-demo --auth-mode login --query "properties.publicAccess" -o tsv 2>&1
