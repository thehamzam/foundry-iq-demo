using './main.bicep'

// Public template only. Supply deployment-specific values from a private local
// environment. Do not commit tenant, principal, resource, or app-role IDs.
param tenantId = readEnvironmentVariable('AZURE_TENANT_ID')
param grants = json(readEnvironmentVariable('TENANT_APP_ROLE_GRANTS_JSON'))
