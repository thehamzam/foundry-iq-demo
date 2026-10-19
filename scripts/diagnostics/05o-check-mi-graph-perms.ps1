#!/usr/bin/env pwsh
# Check whether the Search service MI itself (not the federated SP) has any
# Microsoft Graph app-permissions. If it does, Foundry IQ KB can look up the
# caller's transitive group memberships at query time via Graph — which is
# what makes permission trimming work even when the token's `groups` claim
# is truncated (the default).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid]$SearchManagedIdentityPrincipalId,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid]$FederatedPrincipalId,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid]$SearchApplicationClientId
)

$ErrorActionPreference = 'Continue'
$gt = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
$h = @{ Authorization = "Bearer $gt" }

$graphSp = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals(appId=''00000003-0000-0000-c000-000000000000'')' -Headers $h
$graphSpId = $graphSp.id

foreach ($principal in @(
    @{ name = 'Search managed identity'; oid = $SearchManagedIdentityPrincipalId },
    @{ name = 'Federated runtime service principal'; oid = $FederatedPrincipalId }
)) {
    Write-Host "`n=== $($principal.name) — Graph app roles ===" -ForegroundColor Cyan
    try {
        $r = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.oid)/appRoleAssignments" -Headers $h
        $graphOnly = $r.value | Where-Object { $_.resourceId -eq $graphSpId }
        if ($graphOnly.Count -eq 0) { Write-Host "  (no Graph app-permissions)" -ForegroundColor Yellow }
        else {
            foreach ($a in $graphOnly) {
                $roleName = ($graphSp.appRoles | Where-Object id -eq $a.appRoleId).value
                Write-Host "  $roleName"
            }
        }
    }
    catch { Write-Host "  err: $($_.ErrorDetails.Message)" -ForegroundColor Red }
}

Write-Host "`n=== federated identity credentials on Search MI ===" -ForegroundColor Cyan
try {
    # federated credentials are on the App Registration, not on the SP. Look up the App Registration.
    $searchApp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications(appId='$SearchApplicationClientId')" -Headers $h
    $fic = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications/$($searchApp.id)/federatedIdentityCredentials" -Headers $h
    if ($fic.value.Count -eq 0) { Write-Host "  (none)" -ForegroundColor Yellow }
    foreach ($f in $fic.value) {
        Write-Host "  $($f.name)  issuer=$($f.issuer)  subject=$($f.subject)"
    }
}
catch { Write-Host "  (Search MI is likely a system-assigned MI, no App Registration to inspect)" -ForegroundColor DarkGray }
