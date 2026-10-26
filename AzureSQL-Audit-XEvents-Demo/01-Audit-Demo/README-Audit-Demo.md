# Azure SQL Auditing — portal setup, SQL activity, KQL evidence

**Core flow:** portal setup → Log Analytics only → small SQL test → block 0 →
activity SQL → KQL. Keep optional authentication, alerts and storage until later.
Allow setup and ingestion time before presenting. A new diagnostic setting can
take up to 90 minutes to start delivery; established resource-log delivery is
usually 3–10 minutes. A successful portal save is not proof of delivery.

## 1. Create the lab in the portal

Portal labels and available options vary. Use the equivalent blade if a label
differs. Do not run deployment, configuration or cleanup automation.

| Setting | Value |
|---|---|
| Subscription | `5843dbdc-1f22-4fa4-b744-cd01df71f7af` |
| Region | **East US** for all regional resources |
| Resource group | `rg-auditdemo` |
| Workspace | `log-auditdemo2` |
| SQL server | `<server-name>` = `sql-auditdemo-petartr-1025` |
| Database | `sqldb-auditdemo` |
| Storage, later | `<storage-account>` = `stauditpetartr1025` |
| Network security perimeter / profile | `nsp-auditdemo` / `defaultProfile` |

You need rights to create resources/configure auditing and read workspace logs.
For the optional storage identity role assignment, you also need permission to
assign Azure roles (for example Owner or User Access Administrator at that scope).

1. **Resource groups → Create:** choose the subscription, `rg-auditdemo`, East US.
2. **Log Analytics workspaces → Create:** choose that group, `log-auditdemo2`, East US.
3. **SQL databases → Create:** group `rg-auditdemo`, name `sqldb-auditdemo`.
   Under **Server → Create new**, use `sql-auditdemo-petartr-1025` and
   East US. Prefer **Microsoft Entra-only authentication** and set
   `petartr@microsoft.com` as Microsoft Entra administrator. No SQL password is
   needed for the core demos. If the wizard differs, configure the Entra admin
   on the server's Microsoft Entra ID blade before connecting.
4. Choose an inexpensive development compute tier available in the subscription;
   serverless or Basic is sufficient for the core audit demo. Review cost and
   auto-pause choices. Use locally redundant backup storage if policy permits.
5. **Networking:** this tenant requires the NSP configuration below. Management-group
   `MCAPSGovDeployPolicies` policies `AzureSQL_PublicNetwork_Modify` and
   `StorageAccount_PublicNetwork_Modify` force **Public network access = Disabled**
   at creation, even when the form requests a public endpoint. They accept
   **SecuredByPerimeter**; do not try exclusion tags, policy changes, “all networks,”
   or broad “allow Azure services” access. Complete step 1a before connecting.
   In the creation wizard choose **No access** and **do not add the current
   client IP** or create a normal firewall rule. The automatic add-client-IP step
   was denied by `DenyPublicEndpointEnabled` after policy disabled PNA, causing
   the overall deployment to report Failed even though the server and sample
   database were online. If that occurs, inspect each deployed resource before
   retrying; do not assume the database failed or recreate it blindly.
6. **Additional settings → Use existing data → Sample** opens the
   **AdventureWorksLT confirmation modal: select OK**. Without that confirmation,
   the wizard can remain on **Blank**. Verify **Sample / AdventureWorksLT** is
   selected before **Review + create**, then wait for deployment completion.
7. **Enable the SQL server identity before auditing:** SQL logical server
   `sql-auditdemo-petartr-1025` → **Security → Identity → System assigned → On →
   Save**. Wait for completion and confirm its object ID. Do not defer this to
   the XEvents walkthrough. This prepares the identity for intra-perimeter
   communication; it does not prove audit delivery or establish the cause of
   an earlier ingestion delay.
8. After completing the secure-networking gate below, in SSMS or VS Code MSSQL connect to
   `<server-name>.database.windows.net`, explicitly choose `sqldb-auditdemo`,
   and use **Microsoft Entra MFA/interactive** as `petartr@microsoft.com`.
   Run `SELECT TOP (5) * FROM SalesLT.Customer;`. Confirm rows before continuing.
   Use a persistent SQL client session, not the portal Query editor, for the
   impersonation batches later.

### 1a. Required secure networking in this tenant — Azure portal

Storage can be provisioned now for the perimeter, but **do not enable the audit
storage destination until block 0 succeeds**.

1. Create/verify `stauditpetartr1025` in `rg-auditdemo`, **East US**, using the
   [XE runbook's account settings](../02-XEvents-Demo/README-XEvents-Demo.md#2-create-the-shared-storage-and-identity-in-the-portal).
   Public network access being forced to Disabled is the observed policy effect,
   not by itself a diagnosed audit-pipeline failure.
2. In **Network security perimeters**, create/verify **`nsp-auditdemo`**, East US,
   in `rg-auditdemo`, with profile **`defaultProfile`**.
3. Associate **all three lab resources** to that same perimeter/profile:
   SQL server `sql-auditdemo-petartr-1025`, storage account
   `stauditpetartr1025` and Log Analytics workspace `log-auditdemo2`.
   Do not select unrelated resources.
   [Azure Monitor NSP guidance](https://learn.microsoft.com/azure/azure-monitor/fundamentals/network-security-perimeter)
   requires supported resource diagnostic sources and their destination to share
   the perimeter; keeping this workspace outside is not the required export path.
4. In the profile's **Inbound access rules**, add/verify **`presenter-ip`** for
   the presenter's current public IPv4 address as a single-host `/32`.
   Get the current public IPv4 address in PowerShell:

   ```powershell
   Invoke-RestMethod https://api.ipify.org
   ```

   Append **`/32`** to allow only that address. The rehearsal address was
   **`80.203.61.50/32`**; do not assume it is still current.
   Recheck after a network/VPN change and update this one rule through the portal.
   Never substitute `0.0.0.0/0`, an entire broad network, or an Internet allow rule.
5. Set **all three associations to Enforced** (not merely learning/transition
   mode), and set/verify SQL/storage **Public network access = SecuredByPerimeter**
   using the portal's available resource/association controls. Verify the saved
   state; a submitted change is not a successful connection test.
   For the workspace, keep underlying **public network access for ingestion and
   query Enabled**; NSP enforcement governs access. Do not manually apply
   SQL/storage's SecuredByPerimeter enum to workspace settings. The profile's
   narrow presenter-IP rule also permits network access for log queries;
   workspace read permissions are still required.
6. Confirm the SQL server **system-assigned managed identity is On before enabling
   auditing and testing ingestion**, as described in setup step 7. Before the
   later XE/audit-storage tests, also assign that identity **Storage Blob Data
   Contributor** on the shared storage account. Same-perimeter communication
   does not replace authentication or blob data authorization. Keep `xevents`
   private and anonymous blob access off.
7. Verify the workspace's **same-perimeter membership and Enforced Succeeded**
   state before testing diagnostic export. Keep the existing master audit
   diagnostic route to that workspace. For destinations outside the perimeter,
   identify an **explicitly supported outbound path** for that feature with the
   network/policy owner; do not invent a broad Internet rule or assume public
   destination ingress alone permits SQL egress.
8. **Gate:** test the Entra SQL connection and sample query; then test audit
   block 0 separately. Later, verify actual XE blob writes/reads. Inspect
   perimeter access logs and precise errors when blocked. Do not claim NSP
   enforcement, outbound export or storage delivery is working until verified.
   With SecuredByPerimeter and enforced associations, the narrow NSP inbound
   rule is the access control for this connection; do not add a normal SQL
   client-IP firewall rule. A successful Entra connection/sample query proves
   that SQL path only, not Log Analytics ingestion or storage delivery.

Portal labels can differ. If the required supported controls are unavailable or
policy denies a change, record the limitation and stop that data-path test;
do not disable enforcement or modify/exclude the governing policies.

**Rehearsal checkpoint (2026-10-25):** workspace association reached Enforced
Succeeded at ~17:02 UTC. SQL/storage remained Enforced/SecuredByPerimeter.
All three associations were Enforced Succeeded when marker
`AuditDemo-SamePerimeter-20261025` event `17:02:46.6256916Z` was ingested at
`17:03:32.9722791Z` (~46 seconds). Exact block 0 returned 37 user-database events
(last `17:02:46Z`, average ingestion delay ~192 seconds, minutes since last 1),
plus two blank-database metadata records. Earlier 35 events were historical:
workload between ~16:49 enforcement and ~17:02 workspace association was absent.
Diagnostic export stopped with the destination outside NSP and resumed after
workspace association; **same-three-resource perimeter delivery is verified**.

**Optional visibility gate:** NSP **Monitoring → Diagnostic settings** reported
“Feature not enabled” and required subscription feature enablement in this
rehearsal. No NSP diagnostic setting was created and no subscription feature
registered. Access logs are optional troubleshooting visibility, not a prerequisite
for the successful SQL audit path. If unavailable, record the limitation and use
fresh audit markers and actual timestamps; do not register features or weaken
network controls just to complete the core demo.

## 2. Enable auditing to Log Analytics ONLY

1. Open the **SQL logical server**, not just the database → **Security → Auditing**.
2. Turn **Azure SQL Auditing** on.
3. Select **Log Analytics** and `log-auditdemo2` in the correct subscription.
   Leave **Storage** and **Event Hub** off for this first test.
4. Save. Record the save time and confirm the workspace selection persisted.

The normal portal default uses three audit groups:
`BATCH_COMPLETED_GROUP`, `SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP`, and
`FAILED_DATABASE_AUTHENTICATION_GROUP`. This kit uses that policy, not a custom
granular security policy. Statements can appear as batch-completed records;
separate `CR`, `G`, `APRL`, `IMP` or other granular action IDs are **not guaranteed**.

The Log Analytics route also uses a diagnostic setting for
`SQLSecurityAuditEvents` on the server's **master database**. The portal normally
wires this when auditing is saved. Do not delete existing diagnostic settings
or add duplicate routes as a troubleshooting shortcut. The master resource is
not always exposed in the portal's normal database list; if inspection is not
available in your UI, record that limitation rather than switching to scripts.

## 3. Prove the pipeline before adding anything else

1. Open a new Entra SQL connection to `sqldb-auditdemo` after auditing was enabled.
2. Run this small marker batch and record its UTC timestamp:

   ```sql
   SELECT N'AuditDemo-PipelineCheck' AS Marker,
          DB_NAME() AS DatabaseName, SYSUTCDATETIME() AS GeneratedAtUtc;
   ```

3. Open `log-auditdemo2` → **Logs**, use **KQL mode**, set the time picker to at
   least the last 24 hours, and execute **block 0** from `04-Audit-KQL-Demo.kql`.
4. Wait for ingestion and retry. **Gate:** block 0 must return
   `SQLSecurityAuditEvents` rows for the actual server/database with a relevant
   timestamp. `master` need not have rows unless activity occurred there.
5. Run block **1b** and look for the marker statement. Missing columns may be
   blank; an absent `AzureDiagnostics` table means there is not yet evidence of
   ingestion, not that the query should be replaced with invented results.

If this gate fails, stop here: do not add storage or change several settings at
once. Capture observed results and isolate the route as described below.

## 4. Generate the audit story

**First disconnect and establish a new Entra SQL connection to the user database
after auditing is enabled.** A new query tab on an existing connection is not a
new sign-in. Opening the connection is the producer for KQL block 3; a SELECT
only labels that connection, and `EXECUTE AS` cannot produce a real login.

Open `03-Generate-Audit-Activity.sql` as the Entra admin. Run its numbered sections
in order, keeping the same connection across each section's `GO` batches.
After each section, allow ingestion and run the corresponding KQL block.
Alternatively run the complete file on the new connection and investigate later.
It creates `demo_analyst`
**WITHOUT LOGIN**: impersonation needs no password and does not require an
Entra directory lookup or another real person.

| Run this producer first | Then run KQL | What to look for |
|---|---|---|
| Section 0: fresh pipeline marker | 0, 1a, 1b, 2 | Fresh marker statement, schema and timeline |
| New authenticated connection; section 1 labels it | 3 | Real DBAS event if captured; the BCM marker alone is not login evidence |
| Entire section 2: user, permissions, impersonation and temporary role membership | 6 | Privilege-related completed-batch sequence |
| Section 3: staging-table lifecycle | 7 | TRUNCATE/DROP statement batches |
| Section 4: customer SELECT and larger CROSS JOIN | 8 | Actual read statements and available row counts |
| Sections 0–4: generated workload | 9 | Actual event/billed volume |
| Actual client activity from the above | 10 | Client/IP pairs only if absent from the baseline |
| Section 5: fresh final marker | 0, 1b, 11b | Final marker and recent-source health |

Sections 4/5/12 of the **KQL file** require the separate real-authentication
exercise below and are not populated by this password-free SQL file. KQL 11a
depends on emitted audit-configuration events; it can remain empty under the
default policy. Do not toggle auditing or weaken authentication to fill a chart.

The SQL demonstrates user creation, SELECT/DENY permissions, sample customer
reads, `EXECUTE AS` / `REVERT`, a caught permission error, temporary `db_owner`
membership, a staging table lifecycle and a larger customer/product read.
The permission error is intentional. Sample row counts and populated audit
fields vary; use actual results. The script removes the elevated membership
after showing it; retain the non-login user until cleanup.

`EXECUTE AS` is **not a real authentication** and must not be presented as one.
Reconnect with Entra to generate successful authentication activity.

## 5. Walk through KQL

Run one complete standalone block at a time (select it, or use Shift+Enter).
Keep the predicates and thresholds intact: an empty hunting query can be a
correct result.

Statement-text matches in blocks 6–8 are **investigation candidates**, not a SQL
parser or proof of successful execution. Comments, string literals and failed
attempts can match; quoted identifiers or dynamic SQL can be missed. Inspect
the full batch, action, principal and result fields. Batch success does not
prove every statement succeeded, especially with caught errors. `PIITextHint`
is a text hint, not proof that a PII column was read; `BulkRead` is unknown
when the row-count field is absent.

| Core block | What to demonstrate |
|---|---|
| 0, 1a, 1b | Delivery, schema and latest raw records |
| 2 | Batch/authentication timeline |
| 3 | Actual authenticated connections; failures only if generated |
| 6 | Privilege-related **batch statement text**; granular IDs only if present |
| 7 | Staging table DROP/TRUNCATE statements |
| 8 | Customer data access, available row counts, large-read indicator |
| 9 | Actual event volume and billed size |

Optional blocks **4, 5, 10, 11a, 11b, 12** cover failure bursts, correlations,
new client IPs, audit configuration signals, silence and alert logic.
Block 11a may be empty under the default policy; use the server's portal
**Activity log** to investigate control-plane changes. Block 11b only lists
servers seen in its lookback: it cannot detect a never-ingested server.
Silence can also mean inactivity or a paused database.

## 6. Optional: manually demonstrate failed authentication

Skip this for the simplest/password-free demo. Failed Entra credentials are
validated upstream and are **not SQL failed-login audit events**; investigate
them in Microsoft Entra sign-in logs instead.
Do not weaken Entra-only authentication just to populate a chart.
**This lab is Entra-only, so skip the SQL-password exercise below unless a
separately approved configuration already permits SQL authentication.**

If SQL authentication is already permitted by the lab's approved configuration:

1. In a **new, unsaved query window**, as the Entra admin, create a separate
   contained user `demo_login` using `CREATE USER demo_login WITH PASSWORD = ...`
   with a strong, one-use password. Enter it interactively in that window, never
   in a tracked SQL file, command history or saved configuration. Do not grant
   `db_owner`; a contained user can connect without additional data privileges.
2. In SSMS **Connect**, choose SQL authentication, `demo_login`, explicitly set
   the database to `sqldb-auditdemo`, and enter an incorrect password.
   Confirm the error is a **login failure**, not firewall, timeout or DNS.
3. A few attempts illustrate failure rows in block 3. For block 4/12's real
   threshold, manually generate at least ten failures from the same IP in one
   five-minute window; otherwise these queries should remain empty.
4. Connect once with the correct password, run `SELECT USER_NAME();`, disconnect,
   and allow ingestion. Block 5 is only a correlation candidate, not proof of compromise.
5. As admin run `DROP USER IF EXISTS demo_login;`; close the unsaved window
   without saving the password. There is no required PowerShell workload helper.

## 7. Optional: create a log alert in the portal

Only after real failure records are ingested:

1. In workspace **Logs**, run block **12** unchanged and inspect the result.
2. Choose **New alert rule** (or Monitor → Alerts → Create → Alert rule);
   scope it to `log-auditdemo2` and use the block 12 query.
3. Condition: **number of table rows > 0**, evaluation every five minutes.
   The query's five-minute event-time lookback can miss delayed ingestion;
   evaluate any longer production lookback deliberately and document that change.
   Do not lower the ten-failure threshold just to trigger a demo.
4. Create/select an action group in the portal, enter your notification address,
   name the rule `alert-sql-failed-login-burst`, and choose an appropriate severity.
5. Generate another qualifying burst if desired. Verify the fired alert and
   notification separately; neither is guaranteed at a fixed minute.

## 8. Optional: add the shared storage archive AFTER block 0 succeeds

Follow the storage/identity/network steps in the
[XE runbook](../02-XEvents-Demo/README-XEvents-Demo.md#2-create-the-shared-storage-and-identity-in-the-portal).
Use the **same** `<storage-account>` for both demos, with separate audit and XE
containers. Keep all containers private and anonymous blob access disabled.

Then SQL server → **Auditing** → retain Log Analytics, add **Storage**, choose
the actual storage account, and use **Managed identity** authentication.
Choose a supported retention value such as 90 days if the UI exposes it; retention
zero means unlimited. Save, generate **new** activity and verify `.xel` blobs
under **`sqldbauditlogs/<server-name>/master/`**. Since the July 2025 GA
server-auditing architecture, server audit files are consolidated under `master`
and contain events for all databases; use each record's `database_name` to
select `sqldb-auditdemo`. An empty old `<server-name>/sqldb-auditdemo/` prefix
does **not** establish that no audit records were produced. Older Log Analytics
records are not backfilled into storage.

In `05-Read-Audit-From-Storage.sql`, replace `<storage-account>` and
`<server-name>` and run as Entra admin. Keep the `/master/` prefix and use the
reader's `@DatabaseName` filter (default `sqldb-auditdemo`); set it to NULL only
for deliberate server-wide investigation. Use a narrow blob prefix, not `*`, and
compare records from the period when both destinations were enabled. Missing
blobs are not proof of a particular root cause.

## 9. Cleanup

1. Run the commented cleanup at the end of `03-Generate-Audit-Activity.sql`
   as admin. Drop optional `demo_login` if it exists.
2. Finish the XE demo before deleting shared resources; its SQL cleanup is separate.
3. To keep the lab, disable/delete the demo alert and action group in the portal,
   then disable auditing if no longer needed. Delete unwanted blobs in the portal.
4. To remove the lab, open **Resource groups → rg-auditdemo → Delete resource
   group**, inspect the actual resource list and confirm. Verify deletion.
   Never delete an unrelated resource group based on an old runbook name.

**Recreating the same workspace name:** deleting the resource group can
soft-delete its workspace and reserve the name for **14 days**. If you need to
reuse that name immediately, inspect **Log Analytics workspaces → Recycle bin**.
The portal may require **Recover**, followed by opening the recovered workspace
→ **Delete → Permanent delete**, to release the name. Only do this when
intentionally discarding its data; recovery alone restores the old workspace.
Alternatively choose a new name and use it consistently in auditing, diagnostic
settings, NSP membership and queries. This rebuilt lab uses **`log-auditdemo2`**.
Verify the selected workspace's name and region before continuing.

## Troubleshooting without guessing a root cause

| Observation | Manual checks |
|---|---|
| No audit rows | Correct subscription/server/workspace and time range; auditing save persisted; new SQL marker completed; ingestion delay; workspace ingestion/access and quota settings. Inspect the master audit diagnostic route if exposed. Record what the portal cannot show. |
| SQL connection fails | Entra admin, correct database, actual SecuredByPerimeter/Enforced association state, current presenter `/32` rule, applicable SQL network controls, perimeter access logs and precise error. Network failure is not authentication evidence. |
| Block 6 lacks granular IDs | Expected with the three default groups. Inspect existing batch statement text; do not claim a granular action was captured. |
| Block 4/12 empty | No qualifying ingested burst, five-minute bin boundary, or ingestion delay. Do not reduce thresholds to manufacture success. |
| Storage fails later | Verify SQL/storage are in the same enforced perimeter/profile, managed identity role scope/propagation and exact destination. Same-perimeter networking is not blob authorization. Follow XE guidance; surface policy restrictions. |
| LA stops ingesting after enforcement | Verify SQL, storage and workspace share `nsp-auditdemo/defaultProfile`, all associations are Enforced Succeeded, and workspace ingestion/query settings remain Enabled under NSP. Preserve the master audit route; inspect denied/outbound perimeter logs and test a fresh SQL marker. Membership alone does not prove delivery; do not add broad Internet access. |

Preserve timestamps and error messages; change one setting at a time and re-test.
Zero rows alone does not establish a storage, diagnostic-setting or service root cause.

References: [Auditing setup](https://learn.microsoft.com/azure/azure-sql/database/auditing-setup),
[Initial diagnostic-delivery latency](https://learn.microsoft.com/azure/azure-monitor/data-collection/diagnostic-settings#expected-latency-after-creating-a-diagnostic-setting),
[Current auditing architecture](https://learn.microsoft.com/azure/azure-sql/database/auditing-overview?view=azuresql),
[Azure Monitor NSP](https://learn.microsoft.com/azure/azure-monitor/fundamentals/network-security-perimeter),
[Analyze logs](https://learn.microsoft.com/azure/azure-sql/database/auditing-analyze-audit-logs).
