# Azure SQL Extended Events — portal prerequisites, manual T-SQL demo

**Flow:** portal prerequisites → credential/objects/sessions → **all `05` workloads**
→ **`06` reads** → optional cleanup. Run the errors/cancel, deadlock, blocking and
slow-query scenarios before reading their captured data. Azure Monitor comparison
is optional. All Azure resource/configuration changes are manual portal steps.
**Azure SQL database-scoped XE session creation is T-SQL, not an Azure portal
feature.**

## 1. Start with the shared lab

Follow the [Auditing runbook](../01-Audit-Demo/README-Audit-Demo.md) first,
including its required NSP setup. The shared storage account can exist in NSP
before audit verification; keep the **audit storage destination off** until
**block 0 returns audit rows**. Continue the XE workload after that audit gate.

| Setting | Value |
|---|---|
| Subscription | `5843dbdc-1f22-4fa4-b744-cd01df71f7af` |
| Resource group / region | `rg-auditdemo` / **East US** |
| Workspace / database | `log-auditdemo2` / `sqldb-auditdemo` |
| Server | `<server-name>` = `sql-auditdemo-petartr-1025` |
| Shared storage | `<storage-account>` = `stauditpetartr1025` |
| Network security perimeter / profile | `nsp-auditdemo` / `defaultProfile` |
| SQL sign-in | Entra MFA/interactive, `petartr@microsoft.com` |

Use SSMS or VS Code MSSQL connected explicitly to the user database, **not
master**. Use the Entra admin for this disposable lab; creating the database
credential requires CONTROL, creating sessions requires database event-session
permissions, and reading the DMVs requires database-state visibility. No stored
password, Az module, CLI, deployment template or settings file is required.

## 2. Create the shared storage and identity in the portal

If already created for NSP or optional audit storage, verify these settings rather
than creating another account.

1. **Storage accounts → Create:** subscription above, group `rg-auditdemo`,
   `stauditpetartr1025`, **East US**, **Standard**, general-purpose
   v2 / StorageV2, **Hot**, **LRS** for the non-zone-redundant demo database.
   If the database is zone redundant, check the supported matching redundancy
   requirements before proceeding.
2. Keep **hierarchical namespace disabled**. Require secure transfer and TLS 1.2
   or later. Set **Allow enabling anonymous access on individual containers =
   Disabled**. Do not enable anonymous blob access at any point.
3. Configure **Networking** through the tenant's required NSP path below.
   `StorageAccount_PublicNetwork_Modify` forces Disabled on create, regardless
   of the form; **SecuredByPerimeter** is the supported compliant alternative.
4. After creation, **Data storage → Containers → + Container**, name `xevents`,
   **Private (no anonymous access)**. Portal container creation can use the
   control plane and succeed without your own blob data role; browsing blob
   contents still requires data authorization and an approved network route.
   Container creation alone does not test the SQL managed identity's data access.
   Do not apply an immutability policy to `xevents`: XE file targets do not
   support immutable containers. An audit archive's retention policy is separate.
5. The SQL logical server's system-assigned identity should already be **On** from
   the Audit setup, before its ingestion test. Confirm it under **Security →
   Identity**; if missing, select **System assigned → On → Save** and wait for
   completion before using the credential.
6. Storage account → **Access control (IAM) → Add role assignment**:
   **Storage Blob Data Contributor** → **Managed identity** → SQL server →
   the actual `<server-name>` → **Review + assign**. Allow time for propagation.
   This is a data-plane role; ordinary Contributor is not a substitute.
7. Copy the container URL:
   `https://<storage-account>.blob.core.windows.net/xevents` (no trailing slash).
   This is `<ContainerUrl>` in the SQL files.

### Storage network gate — RBAC is not a firewall bypass

**For this tenant, use NSP first:** follow
[the Auditing runbook's required network steps](../01-Audit-Demo/README-Audit-Demo.md#1a-required-secure-networking-in-this-tenant--azure-portal).
Management-group `MCAPSGovDeployPolicies` applies both
`StorageAccount_PublicNetwork_Modify` and `AzureSQL_PublicNetwork_Modify`.
Use **`nsp-auditdemo` → `defaultProfile`**, associate **all three lab resources:
SQL server, shared storage account and `log-auditdemo2` workspace**.
Set/verify **Enforced** on all three associations and **SecuredByPerimeter**
on SQL/storage, and use inbound **`presenter-ip`**
with the current presenter **`80.203.61.50/32`** (update if the IP changes).
Do not add a broad Internet rule, an exclusion tag, or alter the modify policies.

SQL/storage in the same perimeter permits the intended internal path, but the
SQL managed identity and **Storage Blob Data Contributor** role remain required.
Verify actual event-file writes/reads; do not treat association creation or a
portal save as proof of delivery. Keep Log Analytics **in the same perimeter**
for resource diagnostic export, following
[Azure Monitor NSP guidance](https://learn.microsoft.com/azure/azure-monitor/fundamentals/network-security-perimeter).
Workspace underlying public-network ingestion/query settings remain **Enabled**;
NSP governs access, and the narrow presenter-IP rule permits network access for
log queries (workspace read permission is still required). Do not set an
unsupported workspace PNA enum. External exports require an **explicitly
supported outbound path** if blocked; do not invent a catch-all egress rule.
Workspace membership reached Enforced Succeeded at ~17:02 UTC on 2026-10-25,
and all three associations were Enforced Succeeded when marker
`AuditDemo-SamePerimeter-20261025` event `17:02:46.6256916Z` was ingested at
`17:03:32.9722791Z` (~46 seconds). **The same-three-resource audit export path
is verified**; the earlier outside-workspace configuration stopped diagnostic
export after enforcement. NSP diagnostic-log visibility was unavailable because
the portal required subscription feature enablement. No NSP diagnostic setting
was created or subscription feature registered; this optional visibility gate
did not prevent the successful audit path or the verified XE captures.

**Other firewall configurations (reference, not an NSP workaround):**
managed identity authenticates the SQL server; network access must separately
be allowed. When permitted by policy and supported by the portal, storage
**Networking → Resource settings: Virtual networks,
IP addresses, and exceptions → View → Resource instances** (or equivalent)
can expose a rule for **Microsoft.Sql/servers**. In that separately approved
configuration, select **only** `sql-auditdemo-petartr-1025` in the same tenant
and save. This rule permits a
network source; the blob data role is still required. A generic “trusted Azure
services” exception alone does not replace the SQL server resource-instance
rule for XE. Do not switch to SAS or anonymous access.

Do not infer failure solely from **Public network access = Disabled**:
Azure Storage documents that previously configured resource-instance/trusted
service exceptions can remain effective after public network access is disabled.
Inspect the actual exceptions and verify an XE write/read; the setting alone is
not proof that the pipeline is blocked or working.

These firewall exceptions are not a substitute for the enforced NSP configuration
or permission to bypass its controls. If policy prevents a supported path, surface
the restriction to the policy/network owner. Never enable “all networks,”
temporarily weaken policy to expose a control, or assume that adding a private
endpoint automatically gives the SQL XE writer access. With an enforced network
security perimeter, also check that the SQL database and storage account are in
the same perimeter. Record missing controls/policy errors instead of using scripts.

**Gate:** confirm the account/container exist, the identity role is assigned,
and an approved storage network path is possible before running the next step.
Actual event-file write/read verification happens after the workloads in section 5.

## 3. Create the credential and sessions with T-SQL

Use the script-specific edits below rather than changing every file in advance.
Line numbers refer to the current saved scripts; if you insert/delete lines,
also locate the named statement or section. In SSMS, enable line numbers under
**Tools → Options → Text Editor → Transact-SQL → General → Line numbers**.
Keep the quotes/brackets and any filename suffix; replace only `<ContainerUrl>`
with **`https://stauditpetartr1025.blob.core.windows.net/xevents`**, without a
trailing slash. The table gives the executable placeholder locations, not the
examples in comments.

| Script | Edit first | Execute / expected result |
|---|---|---|
| `02-Create-Credential.sql` | Replace `<ContainerUrl>` on **line 39** (`WHERE name`), **40** (`DROP`) and **43** (`CREATE`). Keep `N'...'`, `[...]` and `IDENTITY = 'MANAGED IDENTITY'` on line 44. | Run the whole file in `sqldb-auditdemo` (executable batches **24–63**). Verification query **52–62**: exact URL, `MANAGED IDENTITY`, sanity check `OK`. |
| `04-Setup-Demo-Objects.sql` | No edits. | Run the whole file (**12–103**). Verification **88–102**: five accounts, ten orders, isolation/locking context. Rerunning resets the disposable scenario tables. |
| `03-Create-XE-Sessions.sql` | Replace `<ContainerUrl>` on **46, 104** (credential checks), **177, 242, 317** (targets). Keep `/demo_xe_...` suffixes and `.xel` extensions. | Run the whole file, preserving `GO` batches. Preflight: **19** available objects. Status/targets **361–379**: three RUNNING sessions, seven targets; inspect drop counters. |

`02-Create-Credential.sql` creates a database-scoped credential with
`IDENTITY = 'MANAGED IDENTITY'`. No secret or database master key is needed for
this credential. Verify its name equals the container URL and its identity is
correct.

`03-Create-XE-Sessions.sql` checks the database/credential and lists all **19
required XE objects** (seven events, eight actions, three targets and one
predicate source), including availability/capability metadata. Missing objects
stop later batches before replacing sessions. SQL DDL is still the final
compatibility test: do not assume an action works in Azure SQL Database just
because it exists on SQL Server. This kit uses `sqlserver.username`;
`sqlserver.server_principal_name` is unavailable in the tested Azure SQL Database
and is deliberately omitted. The captured `username` does not necessarily
identify the original authenticated principal after impersonation. If another
object is rejected, retain the preflight output and exact error before changing
the session definition. It creates and starts:

| Session | Captures / targets |
|---|---|
| `demo_xe_errors_deadlocks` | Errors, client attentions, database deadlock XML; ring buffer + blob file |
| `demo_xe_slow_queries` | Batches/RPCs longer than one second; ring buffer + blob file + query-hash histogram |
| `demo_xe_blocking` | Waits longer than two seconds, lock escalation; ring buffer + blob file |

Verify **three RUNNING sessions** and inspect drop counters. Sessions are
`ON DATABASE` with `STARTUP_STATE = OFF`: ad hoc demo sessions, not an always-on
production configuration. Re-running creation replaces them and clears their
in-memory evidence.

Do not stop or recreate these sessions between generating the workloads and
reading them: that clears the in-memory targets.

## 4. Run ALL `05` workload scripts first

Use only the disposable `sqldb-auditdemo` database. These scripts deliberately
cause errors, blocking and CPU work. **Do not run `06` yet.** Deadlock and
blocking scripts require separate connections and coordinated execution;
they are not a set of files to run serially in one window.

| Order / script | Edits | Run this selection / expected result |
|---|---|---|
| 1. `05a-Scenario-Errors.sql` | None. | Run **19–37** for expected errors 8134, 208, 245, 2627 and 50000. Then select **line 51** (`WAITFOR DELAY '00:00:30'`) and run; after about three seconds press **Cancel query** to generate an attention. |
| 2. `05b-Scenario-Deadlock-Window1.sql` + `05c-Scenario-Deadlock-Window2.sql` | None. Open two independent connections to the same DB. | Start `05b` (**28–54**), then within five seconds start `05c` (**18–41**). One transaction gets 1205, the other commits. Ensure both windows finish with `open_transactions = 0`. |
| 3. `05d-Scenario-Blocking-Window1.sql` + `05e-Scenario-Blocking-Window2.sql` | None. Use separate blocker/reader connections. | In `05d`, run **only 29–35**; leave its transaction open. In the reader, run `05e` **18–26**, including `GO`: the plain SELECT returns under RCSI, while `READCOMMITTEDLOCK` waits. |
| 4. Release the `05d` blocker | None. | After about 15 seconds, return to the **original blocker connection**, select **only line 58** (`ROLLBACK TRANSACTION;`) and run. It is inside a comment, so highlight the SQL line alone. Select **line 63** to check zero open transactions; also run `SELECT @@TRANCOUNT;` in the reader connection. |
| 5. `05f-Scenario-Slow-Queries.sql` | None initially. Only increase workload size if measured executions are below the existing capture threshold. | Run the whole file (**24–71**), preserving `GO 3` / `GO 2`. If needed, increase `@Multiplier` at **46** or the workload `TOP` sizes; do not lower the capture predicate in `03`. **70–71** provide a WAITFOR duration/CPU example. |

All `05a`–`05f` workloads are now complete. Keep the XE sessions running and
ensure no deliberately held transaction remains before moving to the reader.

## 5. THEN prepare and run `06-Read-XE-Data.sql`

Replace `<ContainerUrl>` on **lines 293, 384, 442 and 472** with
`https://stauditpetartr1025.blob.core.windows.net/xevents`. Keep the
`/demo_xe_...` suffix and `N'...'` quotes. These are Azure blob **prefix** reads:
**no `*` and no `.xel` extension**. Creation targets in `03` still end in `.xel`.
Keep `@SessionName` on **line 94** as `demo_xe_errors_deadlocks` for the generic
error reader.

Select each complete range below and execute it separately. Include any
`DECLARE`, `INSERT` or CTE setup; selecting only the final SELECT can fail.

| Read after all workloads | Lines in `06` | Expected evidence |
|---|---|---|
| Section 0: session health and targets | **46–80** | Three RUNNING sessions, seven targets; inspect actual drop counters. |
| Section 1: generic live events | **94–134** | Errors/attention and deadlock events with available client/SQL context. |
| Section 2: error summary | **146–180** | Generated error numbers and a client attention if the WAITFOR was cancelled. |
| Section 5: durable error history | **372–387** | Actual stored records with `source_blob`; allow dispatch/write time. |
| Section 5b: exact current blob, optional alternative | **396–416** | Only the current file; earlier rollover files may be omitted. |
| Sections 3a/3b: deadlock graph and processes | **241–281** | The earlier `05b`/`05c` graph, two processes and a victim. Optionally save XML as `.xdl` and reopen in SSMS. |
| Section 3c: durable deadlock graph | **289–296** | The graph read from Blob Storage. |
| Section 2b: live blocking waits | **199–225** | `LCK_M_*` or verified `XACT_WITH_RESOURCE_TO_READ` / `XACT_WITH_RESOURCE_TO_MODIFY` waits from `05d`/`05e`; WAITFOR is not blocking evidence. |
| Section 6b: durable blocking waits | **465–478** | The corresponding persisted lock waits, emitted after those waits ended. |
| Section 4: slow-query histogram | **321–355** | Actual buckets only; zero/unavailable batch hashes and empty Query Store joins are possible. |
| Section 6: durable slow-event summary | **429–459** | Actual slow captures and duration/CPU evidence from the workloads. |

Repeat section 0 for final health. For the shared audit path, run **section 5 of
the Audit `03-Generate-Audit-Activity.sql`**, then after ingestion run Audit KQL
blocks 0/1b in **`log-auditdemo2`**.

The five-second dispatch setting is not an end-to-end storage guarantee.
Inspect actual records rather than fixed counts: the earlier rehearsal had one
histogram bucket, not three proven query hashes. Ring buffers/histograms disappear
on stop/failover; event files remain until deleted/rolled over. Keep read prefixes
narrow. Portal blob browsing also needs your own approved network/data access.

If writes fail, inspect credential URL/database, container existence, identity
role/propagation and network policy. Preserve the actual SQL/storage error.
If policy blocks storage, an explicitly **memory-only** troubleshooting demo
can be shown by omitting each `ADD TARGET package0.event_file (...)` clause
and its separator comma in an unsaved copy of the session SQL, then recreating
the sessions. This does **not** validate storage or the full event-file demo.

## 6. Optional Azure Monitor comparison — portal setup

1. **SQL database sqldb-auditdemo → Monitoring → Diagnostic settings → Add**.
2. Select available categories **Errors, Deadlocks, Blocks, Timeouts** and route
   to `log-auditdemo2`. This database diagnostic setting is separate from the
   server-auditing route on master. Do not replace/delete the audit route.
3. Save **before** rerunning scenarios. Wait for ingestion, then execute
   `07-Compare-AzureMonitor.kql`.
4. Compare the actual platform records with XE. Not every deliberately raised
   error, cancel or short blocking interval is emitted by platform diagnostics;
   empty categories are possible. Do not weaken filters to manufacture matches.

## 7. Cleanup — SQL objects, then portal resources

1. Roll back/close any open scenario transactions in their original windows.
2. Read any ring-buffer evidence you need **before** running `99-Cleanup.sql`.
3. Open `99-Cleanup.sql` in `sqldb-auditdemo`. Normal cleanup needs no edits:
   run **18–56** to stop/drop the sessions and `xedemo` objects, then **73–78**
   to verify zero demo sessions/objects. If you deliberately choose to remove
   an unused credential, replace `<ContainerUrl>` on **63 and 64** with the
   same container URL, then select only those two SQL lines without the
   surrounding comment and execute. Leave any existing master key in place.
4. Blob files are not removed by SQL cleanup. Delete them in the portal if no
   longer needed; do not delete `sqldbauditlogs` while still demonstrating audit storage.
5. Remove optional database diagnostic settings in the portal if keeping the
   lab. When both demos are finished, delete `rg-auditdemo` in the portal after
   checking its contents, or retain selected resources deliberately.

## Troubleshooting

| Observation | Check, without assuming a root cause |
|---|---|
| Session START fails | Exact credential/container URL (no trailing slash), same user database, private container existence, MI role and approved network path; errors 86/5/3 are useful clues, not a complete diagnosis |
| CREATE rejects an event/action | Inspect `03` preflight required-object metadata and exact DDL error. Azure SQL Database does not support every SQL Server action; capture uses `username`, not the unsupported server-principal action |
| Storage 403 or access denied | Check same-perimeter/profile associations, Enforced/SecuredByPerimeter state, managed identity role propagation and access logs. Legacy resource-instance exceptions are not an NSP bypass; Disabled alone does not establish the cause |
| Ring buffer empty | Session is RUNNING; workload occurred after start; correct database and event predicates; stop/recreate cleared memory |
| Slow query absent | Actual duration did not exceed one second; keep threshold intact and measure workload |
| No deadlock | Start second window promptly; inspect actual transactions/locks; rerun after rolling back |
| Blocking reader returns | Plain SELECT under RCSI should return; use the supplied locking-read batch |
| Data loss counters nonzero | Report incomplete capture; narrow capture or adjust memory deliberately, not “near-zero overhead” guarantees |

References: [XE event-file setup](https://learn.microsoft.com/azure/azure-sql/database/xevent-code-event-file),
[Azure blob prefix reads](https://learn.microsoft.com/sql/relational-databases/system-functions/sys-fn-xe-file-target-read-file-transact-sql?view=azuresqldb-current),
[Storage firewall exception precedence](https://learn.microsoft.com/azure/storage/common/storage-network-security-limitations),
[Resource-instance rules](https://learn.microsoft.com/azure/storage/common/storage-network-security-resource-instances),
[Azure SQL XE differences](https://learn.microsoft.com/azure/azure-sql/database/xevent-db-diff-from-svr),
[Deadlocks](https://learn.microsoft.com/azure/azure-sql/database/analyze-prevent-deadlocks).
