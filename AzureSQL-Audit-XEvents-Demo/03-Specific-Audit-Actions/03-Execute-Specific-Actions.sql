/*
  NEW SPECIFIC-ACTION DEMO - run AFTER 01 and 02, not the older activity script.
  SSMS/VS Code, one connection across GO batches, disposable user database only.
  FIRST edit @ExpectedDatabase below to YOUR demo database.
  Do not run on production. No password, real login or sample-data edits.

  Producer -> reader:
    A. CREATE/ALTER/DROP ExpAudit_TableLifecycle -> KQL block 1 (CR/AL/DR).
    B. DELETE then TRUNCATE ExpAudit_DataRemoval -> block 2
       (DL access records plus BCM evidence; inspect statements to distinguish
       DELETE from TRUNCATE, which emitted DL too on the tested engine).
    C. CREATE/ALTER/DROP ExpAudit_User -> block 3 (principal CR/AL/DR).
  Retaining BATCH_COMPLETED intentionally gives additional records per operation.
  SQL result counts prove the demo's effects; an audit permission-check success
  or text match alone does not prove that every statement committed.
*/
SET NOCOUNT ON;
DECLARE @ExpectedDatabase sysname = N'YOUR_DEMO_DATABASE';
IF DB_NAME() <> @ExpectedDatabase OR DB_NAME() IN (N'master', N'tempdb')
   OR @@TRANCOUNT <> 0
   OR OBJECT_ID(N'dbo.ExpAudit_TableLifecycle') IS NOT NULL
   OR OBJECT_ID(N'dbo.ExpAudit_DataRemoval') IS NOT NULL
   OR DATABASE_PRINCIPAL_ID(N'ExpAudit_User') IS NOT NULL
BEGIN
    RAISERROR(N'Stop: wrong database/open transaction/existing ExpAudit objects. Inspect before continuing. If rerunning, clean up only the dedicated demo objects first.',16,1);
    SET NOEXEC ON;
END;
GO
SELECT N'ExpAudit-START' AS Marker, DB_NAME() AS DatabaseName, SYSUTCDATETIME() AS RunStartUtc;
GO

-- A. TABLE LIFECYCLE: leave each DDL operation in its own batch.
CREATE TABLE dbo.ExpAudit_TableLifecycle (Id int NOT NULL PRIMARY KEY);
GO
ALTER TABLE dbo.ExpAudit_TableLifecycle ADD Description nvarchar(50) NULL;
GO
DROP TABLE dbo.ExpAudit_TableLifecycle;
GO
SELECT N'A-TableLifecycle' AS Scenario,
       OBJECT_ID(N'dbo.ExpAudit_TableLifecycle') AS ObjectIdAfterDrop; -- NULL
GO

-- B. DATA REMOVAL: only the table created by this script is modified.
CREATE TABLE dbo.ExpAudit_DataRemoval (Id int NOT NULL PRIMARY KEY, Label nvarchar(30) NOT NULL);
GO
INSERT dbo.ExpAudit_DataRemoval (Id, Label) VALUES (1,N'Keep'),(2,N'Delete'),(3,N'Truncate');
GO
DELETE FROM dbo.ExpAudit_DataRemoval WHERE Id = 2;
GO
SELECT N'B-AfterDelete' AS Scenario, COUNT(*) AS RemainingRows FROM dbo.ExpAudit_DataRemoval; -- 2
GO
TRUNCATE TABLE dbo.ExpAudit_DataRemoval;
GO
SELECT N'B-AfterTruncate' AS Scenario, COUNT(*) AS RemainingRows FROM dbo.ExpAudit_DataRemoval; -- 0
GO

-- C. DATABASE PRINCIPAL: WITHOUT LOGIN does not need directory lookup/password.
CREATE USER ExpAudit_User WITHOUT LOGIN;
GO
ALTER USER ExpAudit_User WITH DEFAULT_SCHEMA = dbo;
GO
SELECT N'C-UserCreated' AS Scenario, name, type_desc, default_schema_name
FROM sys.database_principals WHERE name = N'ExpAudit_User';
GO
DROP USER ExpAudit_User;
GO
SELECT N'C-AfterDropUser' AS Scenario, DATABASE_PRINCIPAL_ID(N'ExpAudit_User') AS PrincipalId; -- NULL
GO
SELECT N'ExpAudit-FINISH' AS Marker, DB_NAME() AS DatabaseName, SYSUTCDATETIME() AS RunEndUtc;
GO
/*
  KEEP the empty data-removal table while inspecting evidence.
  After the walkthrough, select ONLY this statement to clean up:

  DROP TABLE dbo.ExpAudit_DataRemoval;

  Do not rerun the whole file unless the preflight names are free again.
  If a prior run stopped halfway, inspect and explicitly remove ONLY its demo
  tables/user before rerunning. No automated takeover of existing objects.
*/
SET NOEXEC OFF;
GO
