targetScope = 'tenant'

extension microsoftGraphV1_0

@description('Verified immutable key on the SAME existing application. Blocked until separately authorized onboarding; never invent a key.')
@minLength(1)
param applicationUniqueName string

@sealed()
type FederatedCredential = {
  name: string
  issuer: string
  subject: string
  audiences: string[]
  description: string
}

@description('Exact selected-read properties of the existing named FIC.')
param credential FederatedCredential

resource ingestionApplication 'Microsoft.Graph/applications@v1.0' existing = {
  uniqueName: applicationUniqueName

  resource searchCredential 'federatedIdentityCredentials@v1.0' = {
    name: credential.name
    issuer: credential.issuer
    subject: credential.subject
    audiences: credential.audiences
    description: credential.description
  }
}
