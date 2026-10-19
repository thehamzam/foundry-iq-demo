targetScope = 'tenant'

extension microsoftGraphV1_0

@description('Verified immutable key of an existing group after separately authorized onboarding.')
@minLength(1)
param existingGroupUniqueName string

@description('Existing directory object IDs to append to the group.')
param memberObjectIds string[]

resource frontlineGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: existingGroupUniqueName
  displayName: 'DemoFS-Frontline-Staff'
  mailEnabled: false
  mailNickname: 'demofs-frontline-staff'
  securityEnabled: true
  members: {
    relationshipSemantics: 'append'
    relationships: memberObjectIds
  }
}
