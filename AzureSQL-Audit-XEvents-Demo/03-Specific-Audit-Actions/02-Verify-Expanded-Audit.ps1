<#
Read-only configuration gate. Run with the SAME four arguments used for 01.
Does not prove event delivery: run 03, then 04 to establish that separately.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ServerName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WorkspaceResourceId
)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Sql -ErrorAction Stop
$context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
$policy = Get-AzSqlServerAudit -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DefaultProfile $context
$required = @(
    'SCHEMA_OBJECT_CHANGE_GROUP'
    'SCHEMA_OBJECT_ACCESS_GROUP'
    'DATABASE_PRINCIPAL_CHANGE_GROUP'
    'BATCH_COMPLETED_GROUP'
)
$groups = @($policy.AuditActionGroup | ForEach-Object { $_.ToString() })
$missing = @($required | Where-Object { $_ -notin $groups })
if ($missing.Count) { throw "Required audit groups missing: $($missing -join ', ')" }
if ($policy.LogAnalyticsTargetState -ne 'Enabled' -or
    $policy.WorkspaceResourceId.TrimEnd('/') -ine $WorkspaceResourceId.TrimEnd('/')) {
    throw 'Log Analytics destination is disabled or differs from the requested workspace.'
}
if (-not [string]::IsNullOrWhiteSpace($policy.PredicateExpression)) {
    throw 'An audit predicate is present. Verify it does not exclude these scenarios before proceeding.'
}
$master = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Sql/servers/$ServerName/databases/master"
$response = Invoke-AzRestMethod -Method GET `
    -Path "$master/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" `
    -DefaultProfile $context -ErrorAction Stop
if ($response.StatusCode -ne 200) { throw "Diagnostic-setting read failed: HTTP $($response.StatusCode)" }
$settings = ($response.Content | ConvertFrom-Json).value
$routes = @($settings | Where-Object {
    $_.properties.workspaceId -and
    $_.properties.workspaceId.TrimEnd('/') -ieq $WorkspaceResourceId.TrimEnd('/') -and
    @($_.properties.logs | Where-Object {
        $_.enabled -and ($_.category -eq 'SQLSecurityAuditEvents' -or $_.categoryGroup -in @('allLogs', 'audit'))
    }).Count -gt 0
})
if (-not $routes.Count) { throw 'No enabled SQLSecurityAuditEvents route from master to the requested workspace.' }
$required | ForEach-Object { [pscustomobject]@{ AuditGroup = $_; Configured = $true } } | Format-Table -AutoSize
Write-Output "Workspace: $($policy.WorkspaceResourceId)"
Write-Output "Diagnostic route(s): $($routes.name -join ', ')"
Write-Output 'CONFIGURATION VERIFIED. Now run 03 in the disposable database, then run 04 in this workspace after ingestion.'
