# AI Gateway monitoring

The AI Gateway module creates a workspace-based Application Insights component
with `AzureMonitorWorkspaceIngestionMode: Enabled`. The property is not yet in
the Bicep type for `Microsoft.Insights/components@2020-02-02`, so the template
documents and suppresses BCP037 for that property.

The `azd` postprovision hook configures native OpenTelemetry monitoring after
Application Insights has created its managed DCR/DCE and OTLP endpoints:

1. Register `Microsoft.Monitor` if it is not already registered.
2. Wait for the Application Insights ingestion endpoints and managed DCR scope.
3. Assign the Gateway system identity **Monitoring Metrics Publisher**
   (`3913510d-42f4-4e42-8a64-420c390055eb`) at the generated DCR scope using a
   direct ARM role-assignment PUT. The managed resource group's deny assignment
   blocks creating this nested role assignment from ARM/Bicep.
4. Create
   `Microsoft.ApiManagement/aigateways/{gatewayName}/telemetryExporters/applicationInsights`
   as `kind: OpenTelemetry`, using the Application Insights resource ID, the
   metrics/logs/traces OTLP endpoints, and managed-identity audience
   `https://monitor.azure.com`.

Exporter `kind` is immutable. The hook deletes an existing exporter with a
different kind before recreating it as OpenTelemetry. The preview service can
omit `tracesEndpoint` from exporter GET responses; metrics and logs are enough
for the portal dashboard eligibility check.
