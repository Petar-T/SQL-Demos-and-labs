/*==============================================================================
  GENERATE AUDIT ACTIVITY - disposable AdventureWorksLT demo database only
  Run as: Microsoft Entra admin
  Database: sqldb-auditdemo, NOT master
  Client: SSMS / VS Code MSSQL; keep one connection across each section's GO batches.

  BEFORE RUNNING:
    1. Enable SERVER auditing to your actual workspace (this rebuilt lab uses
       log-auditdemo2), with the portal's three default action groups.
    2. DISCONNECT, then establish a NEW Entra connection to sqldb-auditdemo.
       A new query tab on an existing connection is NOT sufficient.
       Opening the connection is the login producer; SELECT and EXECUTE AS
       cannot manufacture authentication events in an existing SQL session.
    3. Start with no open transaction. Run section 0, then follow the pairs below.

  PRODUCER FIRST: run a numbered section -> allow ingestion -> run its KQL.
  You can also run the whole file on the new connection and inspect KQL later.

    SQL section / real action          KQL block          Expected evidence
    0  Fresh pipeline marker           0, 1a, 1b, 2       Fresh BCM statement
    1  NEW connection + login marker   3                  DBAS if captured
    2  User/permissions/role activity   6                  Privilege batch text
    3  Staging-table lifecycle         7                  TRUNCATE/DROP batches
    4  Customer and larger reads       8                  SELECT/CROSS JOIN text
    0-4 All generated workload         9                  Event/billed volume
    1-4 Actual client activity         10                 New IP if no baseline
    5  Final marker                    0, 1b, 11b         Recent event / health

  Use 04-Audit-KQL-Demo.kql in the SAME actual destination workspace.
  First diagnostic-setting delivery can take up to 90 minutes. Established
  resource-log delivery is usually minutes, not immediate. Do not repeatedly
  toggle/resave auditing while waiting. Compare fresh timestamps, not old rows.

  Portal defaults audit completed batches and successful/failed authentication.
  Granular CR/G/APRL/IMP IDs and optional row counts are NOT guaranteed.
  Text matches are investigation candidates, not proof every statement succeeded.

  OPTIONAL HUNTS, NOT PRODUCED BY THIS PASSWORD-FREE SCRIPT:
    4 / 5 / 12 require REAL failed SQL authentications, and a subsequent real
    success for block 5. EXECUTE AS, error 229 and failed Entra credentials are
    not DBAF SQL login events. Do not enable SQL-password authentication just
    to fill these queries. See README section 6 if separately approved.
    11a needs emitted AUSC policy-change records. Do not toggle auditing merely
    to force one; use the Azure Activity log when the default policy emits none.
    10 can be empty with an existing client-IP baseline; do not invent an IP.
==============================================================================*/
SET NOCOUNT ON;
GO

/* 0. PREFLIGHT + PIPELINE PRODUCER -> KQL 0 / 1a / 1b / 2.
   Run before changing any demo objects. The marker must appear as a NEW audit
   statement in the destination workspace before proceeding with the story.
*/
IF DB_NAME() <> N'sqldb-auditdemo'
BEGIN
    RAISERROR (N'Stop: connect to the disposable sqldb-auditdemo database.', 16, 1);
    SET NOEXEC ON;
END;
IF @@TRANCOUNT <> 0
BEGIN
    RAISERROR (N'Stop: finish your existing transaction before running this demo.', 16, 1);
    SET NOEXEC ON;
END;
IF OBJECT_ID(N'SalesLT.Customer', N'U') IS NULL
   OR OBJECT_ID(N'SalesLT.Product', N'U') IS NULL
BEGIN
    RAISERROR (N'Stop: this demo requires the AdventureWorksLT sample tables.', 16, 1);
    SET NOEXEC ON;
END;
GO

SELECT N'AuditDemo-00-PipelineCheck' AS Marker,
       DB_NAME() AS CurrentDatabase,
       SUSER_SNAME() AS LoginName,
       SYSUTCDATETIME() AS GeneratedAtUtc;
PRINT N'NEXT: after ingestion, KQL 0/1b must show this NEW marker. Then continue.';
GO

/* 1. AUTHENTICATION PRODUCER -> KQL 3.
   The NEW CONNECTION required in the header generates authentication activity.
   This SELECT labels that connection and produces a separate BCM marker.
   Seeing the marker alone does NOT prove that DBAS has been captured.

   If you connected before auditing was enabled, stop here, disconnect, connect
   again using Entra to this database, then run sections 0 and 1 on that connection.
   Wait for ingestion and inspect the actual action IDs before proceeding.
*/
SELECT N'AuditDemo-01-NewConnection' AS Marker,
       @@SPID AS SessionId,
       SUSER_SNAME() AS LoginName,
       USER_NAME() AS DatabaseUser,
       DB_NAME() AS DatabaseName,
       SYSUTCDATETIME() AS GeneratedAtUtc;
PRINT N'NEXT: KQL 3 needs actual DBAS/DBAF records, not just this marker.';
PRINT N'No failures are generated in this Entra-only flow; failed-login hunts can stay empty.';
GO

/* 2. PRIVILEGE PRODUCER -> KQL 6.
   Run this ENTIRE section, including REVERT and removal of db_owner.
   demo_analyst has no login/password; this is not the KQL 3 login producer.
*/
IF DATABASE_PRINCIPAL_ID(N'demo_analyst') IS NULL
    CREATE USER demo_analyst WITHOUT LOGIN;
IF IS_ROLEMEMBER(N'db_owner', N'demo_analyst') = 1
    ALTER ROLE db_owner DROP MEMBER demo_analyst;
GO

GRANT SELECT ON OBJECT::SalesLT.Customer TO demo_analyst;
DENY UPDATE ON OBJECT::SalesLT.Customer TO demo_analyst;
GO

EXECUTE AS USER = N'demo_analyst';
GO
BEGIN TRY
    SELECT USER_NAME() AS RunningAs;
    SELECT TOP (25) EmailAddress, Phone
    FROM SalesLT.Customer
    ORDER BY CustomerID;
    BEGIN TRY
        UPDATE SalesLT.Customer
        SET Phone = Phone
        WHERE CustomerID = 1;
        THROW 51001, N'Expected UPDATE to be denied; stop and inspect demo permissions.', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() <> 229
            THROW;
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ExpectedError;
    END CATCH;
END TRY
BEGIN CATCH
    REVERT;
    THROW;
END CATCH;
GO
REVERT;
SELECT USER_NAME() AS RunningAsAfterRevert;
GO

ALTER ROLE db_owner ADD MEMBER demo_analyst;
GO
SELECT IS_ROLEMEMBER(N'db_owner', N'demo_analyst') AS AnalystIsDbOwner; -- Expect 1
GO
ALTER ROLE db_owner DROP MEMBER demo_analyst;
GO
SELECT IS_ROLEMEMBER(N'db_owner', N'demo_analyst') AS AnalystIsDbOwnerAfterRemoval, -- Expect 0
       SYSUTCDATETIME() AS GeneratedAtUtc;
PRINT N'NEXT: after ingestion, run KQL 6 for the user/permission/role batch sequence.';
GO

/* 3. DESTRUCTIVE DDL PRODUCER -> KQL 7.
   Only the disposable dbo.AuditDemo_Staging table is created/changed/dropped.
   Each operation is a separate batch so its completed statement can be read.
*/
DROP TABLE IF EXISTS dbo.AuditDemo_Staging;
GO
CREATE TABLE dbo.AuditDemo_Staging
(
    CustomerID int NOT NULL PRIMARY KEY,
    EmailAddress nvarchar(50) NULL,
    Phone nvarchar(25) NULL
);
GO
INSERT INTO dbo.AuditDemo_Staging (CustomerID, EmailAddress, Phone)
SELECT CustomerID, EmailAddress, Phone FROM SalesLT.Customer;
GO
ALTER TABLE dbo.AuditDemo_Staging ADD ExportedAtUtc datetime2(0) NULL;
GO
TRUNCATE TABLE dbo.AuditDemo_Staging;
GO
DROP TABLE dbo.AuditDemo_Staging;
GO
SELECT N'AuditDemo-03-StagingFinished' AS Marker,
       OBJECT_ID(N'dbo.AuditDemo_Staging', N'U') AS StagingObjectId, -- Expect NULL
       SYSUTCDATETIME() AS GeneratedAtUtc;
PRINT N'NEXT: after ingestion, run KQL 7 for the staging-table lifecycle.';
GO

/* 4. SENSITIVE-READ PRODUCER -> KQL 8; VOLUME -> KQL 9.
   Expect 50 customer rows, then a larger CROSS JOIN result. Optional audit
   response-row counts may be missing even when statement text is present.
*/
SELECT TOP (50) CustomerID, FirstName, LastName, EmailAddress, Phone
FROM SalesLT.Customer
ORDER BY CustomerID;
GO
SELECT c.CustomerID, c.EmailAddress, c.Phone, p.Name AS ProductName
FROM SalesLT.Customer AS c
CROSS JOIN (SELECT TOP (20) Name FROM SalesLT.Product ORDER BY ProductID) AS p;
GO
SELECT N'AuditDemo-04-ReadsFinished' AS Marker,
       SYSUTCDATETIME() AS GeneratedAtUtc;
PRINT N'NEXT: after ingestion, run KQL 8 for reads and KQL 9 for actual audit volume.';
GO

/* 5. FRESHNESS / WRAP-UP PRODUCER -> KQL 0 / 1b / 11b.
   All preceding activity also feeds the schema, timeline, volume and new-IP
   queries. A fresh lab has no IP baseline; an established lab might have one.
*/
SELECT N'AuditDemo-05-ActivityComplete' AS Marker,
       DB_NAME() AS DatabaseName,
       SYSUTCDATETIME() AS GeneratedAtUtc;
PRINT N'NEXT: KQL 0/1b must include this new final marker after ingestion; 11b should show recent activity.';
PRINT N'Optional KQL 4/5/11a/12 have separate prerequisites; this script does not populate them.';
GO

/* OPTIONAL CLEANUP - select only after finishing the KQL walkthrough.
   Run as admin, not in an impersonated context.
*/
-- IF IS_ROLEMEMBER(N'db_owner', N'demo_analyst') = 1
--     ALTER ROLE db_owner DROP MEMBER demo_analyst;
-- DROP USER IF EXISTS demo_analyst;
-- DROP USER IF EXISTS demo_login;
-- DROP TABLE IF EXISTS dbo.AuditDemo_Staging;
PRINT N'Cleanup is commented out; preserve the audit evidence before cleaning up.';
GO
SET NOEXEC OFF;
GO
