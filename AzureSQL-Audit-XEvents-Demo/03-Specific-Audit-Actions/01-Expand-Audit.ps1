<#
Run manually in Azure Cloud Shell (PowerShell), which includes Az.Accounts/Az.Sql.
Use the subscription/server/workspace of THIS demo, not the old lab defaults.

.\01-Expand-Audit.ps1 -SubscriptionId <guid> -ResourceGroupName <rg> `
    -ServerName <server> -WorkspaceResourceId <full-workspace-resource-id> -WhatIf

Rerun without -WhatIf to apply. Then run 02-Verify-Expanded-Audit.ps1.
This is a server-wide policy change: all databases on this logical server inherit
the added groups. Use a disposable demo server. No Azure role assignment needed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
if ($policy.LogAnalyticsTargetState -ne 'Enabled' -or
    $policy.WorkspaceResourceId.TrimEnd('/') -ine $WorkspaceResourceId.TrimEnd('/')) {
    throw 'First enable Log Analytics auditing to the requested workspace in the portal, and prove baseline ingestion.'
}
if ($policy.BlobStorageTargetState -eq 'Enabled' -or $policy.EventHubTargetState -eq 'Enabled') {
    throw 'This isolated demo requires Log Analytics-only auditing. Do not change a multi-destination server with this script.'
}
if (-not [string]::IsNullOrWhiteSpace($policy.PredicateExpression)) {
    throw 'An audit predicate is present and might exclude demo actions. Review it explicitly before using this demo.'
}
$required = @(
    'SCHEMA_OBJECT_CHANGE_GROUP'
    'SCHEMA_OBJECT_ACCESS_GROUP'
    'DATABASE_PRINCIPAL_CHANGE_GROUP'
    'BATCH_COMPLETED_GROUP'
)
$before = @($policy.AuditActionGroup | ForEach-Object { $_.ToString() })
$expanded = @(@($before) + $required | Sort-Object -Unique)
Write-Output 'Existing groups (retain this output if you later restore the policy):'
$before | Write-Output
Write-Output 'Proposed groups:'
$expanded | Write-Output
Write-Warning 'SCHEMA_OBJECT_ACCESS_GROUP captures access beyond DELETE, potentially including SELECT/INSERT/UPDATE across the server. Batch plus granular records intentionally overlap and increase volume.'
if (-not @($required | Where-Object { $_ -notin $before }).Count) {
    Write-Output 'All required groups are already configured. Run 02 to verify the route.'
    return
}
if ($PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroupName/$ServerName", 'Add custom audit groups, retaining existing groups and the Log Analytics destination')) {
    Set-AzSqlServerAudit -ResourceGroupName $ResourceGroupName -ServerName $ServerName `
        -AuditActionGroup $expanded -DefaultProfile $context -ErrorAction Stop | Out-Null
    Write-Output 'Update completed. Run 02-Verify-Expanded-Audit.ps1 before executing SQL.'
}
