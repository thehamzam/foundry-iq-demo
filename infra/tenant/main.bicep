targetScope = 'tenant'

extension microsoftGraphV1_0

@description('Directory containing the existing application permission assignments.')
param tenantId string

output expectedTenantId string = tenantId

@sealed()
type Grant = {
  principalId: string
  resourceId: string
  appRoleId: string
}

@description('Existing, selected-read verified assignments only; never an empty successful adoption.')
@minLength(3)
@maxLength(3)
param grants Grant[]

resource assignments 'Microsoft.Graph/appRoleAssignedTo@v1.0' = [for grant in grants: {
  principalId: grant.principalId
  resourceId: grant.resourceId
  appRoleId: grant.appRoleId
}]
