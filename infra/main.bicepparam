using './main.bicep'

// Safe disposable defaults. Storage is private; Search and Foundry retain
// keyless public endpoints for local and hosted agent validation.
param environment = 'foundry-quickstart'
param location = 'replace-before-deployment'
param deploymentId = 'replace-before-deployment'
param operatorPrincipalId = 'replace-before-deployment'
param functionAuthClientId = 'replace-before-deployment'
param functionAuthAudience = 'replace-before-deployment'
param searchSku = 'standard'
param functionPlanSku = 'P1v3'
param chatModelVersion = 'replace-before-deployment'
param embeddingModelVersion = 'replace-before-deployment'
param tags = {
  workload: 'foundry-quickstart'
  dataClassification: 'synthetic'
}
