/*==============================================================================
  STEP 5 (OPTIONAL) - READ RAW AUDIT RECORDS FROM STORAGE WITH T-SQL
  File    : 05-Read-Audit-From-Storage.sql
  Run as  : server admin (SQL admin or Microsoft Entra admin)
  Database: sqldb-auditdemo (or master). Requires CONTROL DATABASE.
            Server admins can read the audit logs of ALL databases on the server;
            non-admins only those of the current database (other blobs are skipped).

  WHY SHOW THIS?
    Storage is the cheap, long-retention evidence archive (.xel files). Log Analytics is
    for hunting and alerting. Same records, two sinks - and auditors can be given
    T-SQL access to the archive without access to the workspace.

  BLOB LAYOUT (server-level audit, consolidated architecture GA July 2025):
    https://<storage-account>.blob.core.windows.net/sqldbauditlogs/<server-name>/master/
        SqlDbAuditing_ServerAudit/<yyyy-mm-dd>/<hh_mm_ss_fff_n>.xel
    (folder suffix _NoRetention, i.e. SqlDbAuditing_ServerAudit_NoRetention, when retention = 0)
    Files under master contain records for ALL databases. Filter database_name
    in the records, not the blob prefix, to select sqldb-auditdemo.
    Zero rows at the old <server-name>/sqldb-auditdemo/ prefix do NOT establish
    that the server produced no audit data.

  "WILDCARDS": on Azure blob URLs an asterisk (*) is NOT supported. Use a PREFIX instead -
    the function reads every blob whose name starts with the given path:
      .../sqldbauditlogs/<server-name>/master/                 -> consolidated server audit
      .../sqldbauditlogs/<server-name>/master/SqlDbAuditing_ServerAudit/2026-10-25/
                                                                -> one day, all databases
    Keep the prefix as narrow as possible: every matching blob is downloaded and parsed.

  sys.fn_get_audit_file_v2 (Azure SQL Database) adds start/end time filtering at FILE and
  record level -> much faster. If v2 is not available, swap to sys.fn_get_audit_file
  (3 arguments) and filter on event_time in the WHERE clause (see query 1b).

  Prerequisite: add the optional storage destination manually in the portal
  AFTER KQL block 0 succeeds. Replace both placeholders with confirmed names.
  Storage access uses the server's managed identity with the portal-assigned
  'Storage Blob Data Contributor' role. If blobs are reported as skipped
  or access is denied, check that role assignment and the storage firewall.
  Statement-text filters below are investigation heuristics, not parsed SQL:
  comments/literals/failed attempts can match. Inspect full records and results;
  a completed batch does not prove every statement in it succeeded.

  Production toolkit (9 more queries): AzureSQL-Observability/01-auditing/03-audit-read-toolkit.sql
==============================================================================*/
SET NOCOUNT ON;
-- One batch, no GO: run the whole file, or select the DECLARE block + ONE query and run it.

-- >>> EDIT THESE TWO PLACEHOLDERS (lower-case server name, no .database.windows.net) <<<
DECLARE @AuditPath nvarchar(260) =
    N'https://<storage-account>.blob.core.windows.net/sqldbauditlogs/<server-name>/master/';
-- Set NULL deliberately for server-wide investigation, including records without a database name.
DECLARE @DatabaseName sysname = N'sqldb-auditdemo';
DECLARE @FromUtc datetime2(0) = DATEADD(HOUR, -4, SYSUTCDATETIME());
DECLARE @ToUtc   datetime2(0) = SYSUTCDATETIME();


/*------------------------------------------------------------------------------
  1. LATEST EVENTS - the raw feed, newest first.
     EXPECT: records generated after storage was enabled (typically auth and
             completed batches under the portal default), including file_name.
             Granular privilege action IDs are not guaranteed.
------------------------------------------------------------------------------*/
SELECT TOP (200)
       f.event_time,
       RTRIM(f.action_id)                AS action_id,
       f.succeeded,
       f.session_server_principal_name   AS original_login,
       f.server_principal_name,
       f.database_principal_name,
       f.database_name,
       f.schema_name,
       f.object_name,
       LEFT(f.statement, 300)            AS statement,
       f.client_ip,
       f.application_name,
       f.response_rows,
       f.affected_rows,
       f.file_name
FROM   sys.fn_get_audit_file_v2(@AuditPath, DEFAULT, DEFAULT, @FromUtc, @ToUtc) AS f
WHERE  (@DatabaseName IS NULL OR f.database_name = @DatabaseName)
ORDER BY f.event_time DESC;

/* 1b. Fallback if sys.fn_get_audit_file_v2 is not available (reads ALL matching blobs):
SELECT TOP (200) f.event_time, RTRIM(f.action_id) AS action_id, f.succeeded,
       f.server_principal_name, f.database_principal_name, LEFT(f.statement, 300) AS statement,
       f.client_ip, f.application_name
FROM   sys.fn_get_audit_file(@AuditPath, DEFAULT, DEFAULT) AS f
WHERE  f.event_time BETWEEN @FromUtc AND @ToUtc
  AND  (@DatabaseName IS NULL OR f.database_name = @DatabaseName)
ORDER BY f.event_time DESC;
*/


/*------------------------------------------------------------------------------
  2. FAILED SQL LOGINS - optional manual SQL-password exercise in the README.
     DBAF = database authentication failed.
     EXPECT: actual failures reaching SQL while storage auditing was enabled.
             Empty in this Entra-only lab: failed Entra credentials are checked
             upstream and are not SQL failed-login audit events.
             Network failures do not qualify either.
------------------------------------------------------------------------------*/
SELECT   f.server_principal_name                              AS login_or_user,
         f.client_ip,
         f.application_name,
         COUNT(*)                                             AS FailedAttempts,
         MIN(f.event_time)                                    AS FirstAttemptUtc,
         MAX(f.event_time)                                    AS LastAttemptUtc,
         DATEDIFF(SECOND, MIN(f.event_time), MAX(f.event_time)) AS WindowSeconds
FROM     sys.fn_get_audit_file_v2(@AuditPath, DEFAULT, DEFAULT, @FromUtc, @ToUtc) AS f
WHERE    (@DatabaseName IS NULL OR f.database_name = @DatabaseName)
  AND    f.action_id = 'DBAF'
GROUP BY f.server_principal_name, f.client_ip, f.application_name
ORDER BY FailedAttempts DESC;


/*------------------------------------------------------------------------------
  3. PERMISSION / PRINCIPAL CHANGES - the privilege escalation story.
     APRL/DPRL add/drop role member, G/D/R grant/deny/revoke, GWG grant with grant,
     IMP impersonation, CR/AL/DR on users and roles require relevant coverage.
     Portal default: inspect BCM statement text via the batch predicate below.
     EXPECT: CREATE USER demo_analyst, GRANT SELECT, DENY UPDATE, EXECUTE AS,
             ALTER ROLE db_owner ADD MEMBER demo_analyst.
------------------------------------------------------------------------------*/
SELECT   f.event_time,
         RTRIM(f.action_id)                AS action_id,
         CASE RTRIM(f.action_id)
              WHEN 'APRL' THEN 'ADD ROLE MEMBER'
              WHEN 'DPRL' THEN 'DROP ROLE MEMBER'
              WHEN 'G'    THEN 'GRANT'
              WHEN 'D'    THEN 'DENY'
              WHEN 'R'    THEN 'REVOKE'
              WHEN 'GWG'  THEN 'GRANT WITH GRANT'
              WHEN 'IMP'  THEN 'IMPERSONATE'
              WHEN 'CR'   THEN 'CREATE'
              WHEN 'AL'   THEN 'ALTER'
              WHEN 'DR'   THEN 'DROP'
              WHEN 'BCM'  THEN 'BATCH COMPLETED'
              ELSE RTRIM(f.action_id)
         END                               AS action_name,
         f.session_server_principal_name   AS actor_login,
         f.database_principal_name         AS actor_user,
         f.target_database_principal_name  AS target_user,
         f.object_name,
         LEFT(f.statement, 400)            AS statement,
         f.client_ip,
         f.application_name,
         f.succeeded
FROM     sys.fn_get_audit_file_v2(@AuditPath, DEFAULT, DEFAULT, @FromUtc, @ToUtc) AS f
WHERE    (@DatabaseName IS NULL OR f.database_name = @DatabaseName)
  AND   (RTRIM(f.action_id) IN ('APRL', 'DPRL', 'G', 'D', 'R', 'GWG', 'IMP')
   OR   (RTRIM(f.action_id) IN ('CR', 'AL', 'DR') AND f.class_type IN ('US', 'RL', 'AR'))  -- user, role, app role
   OR   (RTRIM(f.action_id) = 'BCM'
         AND (   f.statement LIKE '%ALTER ROLE%'  OR f.statement LIKE '%GRANT %'
              OR f.statement LIKE '%DENY %'       OR f.statement LIKE '%REVOKE %'
              OR f.statement LIKE '%EXECUTE AS%'  OR f.statement LIKE '%CREATE USER%')))
ORDER BY f.event_time;


/*------------------------------------------------------------------------------
  4. READS ON SalesLT.Customer (sample PII) - BATCH_COMPLETED_GROUP is a portal default.
     EXPECT: matching completed batches. Available row counts depend on the
             emitted fields, batch contents and sample data, not fixed totals.
------------------------------------------------------------------------------*/
SELECT   f.event_time,
         f.session_server_principal_name   AS original_login,
         f.database_principal_name         AS running_as_user,
         f.client_ip,
         f.application_name,
         f.response_rows,
         f.affected_rows,
         f.duration_milliseconds,
         LEFT(f.statement, 400)            AS statement
FROM     sys.fn_get_audit_file_v2(@AuditPath, DEFAULT, DEFAULT, @FromUtc, @ToUtc) AS f
WHERE    (@DatabaseName IS NULL OR f.database_name = @DatabaseName)
  AND    RTRIM(f.action_id) IN ('BCM', 'RCM')
  AND    f.statement LIKE N'%SalesLT.Customer%'
ORDER BY f.event_time;
