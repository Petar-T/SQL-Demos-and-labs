/*==============================================================================
  XEvents DEMO - CLEANUP
  File : 99-Cleanup.sql
  Run  : in the USER database after the demo.

  WHAT   Stop and drop the three demo sessions, drop the xedemo objects,
         optionally drop the credential.
  SAY    "Ad hoc sessions are cheap to create and cheap to throw away. For
         always-on monitoring use STARTUP_STATE = ON and the production
         toolkit instead."
  EXPECT Final check returns 0 sessions and 0 xedemo objects.
  NOTE   - Close / ROLLBACK any demo query windows first (open transactions
           from 05d would block the DROP TABLE).
         - .xel blobs are NOT deleted by dropping a session. Delete them in
           the portal (Storage account > Containers > xevents) or with
           Azure Storage Explorer - or keep them for the post-mortem.
==============================================================================*/
SET NOCOUNT ON;
GO

/*------------------------------------------------------------------------------
  1. Stop running sessions (ring buffer / histogram contents are lost here)
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.dm_xe_database_sessions WHERE name = N'demo_xe_errors_deadlocks')
    ALTER EVENT SESSION [demo_xe_errors_deadlocks] ON DATABASE STATE = STOP;
GO
IF EXISTS (SELECT 1 FROM sys.dm_xe_database_sessions WHERE name = N'demo_xe_slow_queries')
    ALTER EVENT SESSION [demo_xe_slow_queries] ON DATABASE STATE = STOP;
GO
IF EXISTS (SELECT 1 FROM sys.dm_xe_database_sessions WHERE name = N'demo_xe_blocking')
    ALTER EVENT SESSION [demo_xe_blocking] ON DATABASE STATE = STOP;
GO

/*------------------------------------------------------------------------------
  2. Drop the session definitions
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'demo_xe_errors_deadlocks')
    DROP EVENT SESSION [demo_xe_errors_deadlocks] ON DATABASE;
GO
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'demo_xe_slow_queries')
    DROP EVENT SESSION [demo_xe_slow_queries] ON DATABASE;
GO
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'demo_xe_blocking')
    DROP EVENT SESSION [demo_xe_blocking] ON DATABASE;
GO

/*------------------------------------------------------------------------------
  3. Drop the demo objects
------------------------------------------------------------------------------*/
DROP PROCEDURE IF EXISTS xedemo.usp_SlowReport;
DROP TABLE     IF EXISTS xedemo.Orders;
DROP TABLE     IF EXISTS xedemo.Accounts;
GO
IF SCHEMA_ID(N'xedemo') IS NOT NULL
    DROP SCHEMA xedemo;
GO

/*------------------------------------------------------------------------------
  4. OPTIONAL - drop the credential (only if nothing else writes to this
     container from this database, e.g. the production toolkit sessions).
     Replace <ContainerUrl>, then highlight + F5:

IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'<ContainerUrl>')
    DROP DATABASE SCOPED CREDENTIAL [<ContainerUrl>];

     The database master key is left in place on purpose (other features
     may use it).
------------------------------------------------------------------------------*/

/*------------------------------------------------------------------------------
  5. Verify
------------------------------------------------------------------------------*/
SELECT  (SELECT COUNT(*) FROM sys.database_event_sessions
         WHERE name LIKE N'demo[_]xe[_]%')                     AS demo_sessions_left,  -- EXPECT 0
        (SELECT COUNT(*) FROM sys.objects
         WHERE schema_id = ISNULL(SCHEMA_ID(N'xedemo'), -1))   AS xedemo_objects_left, -- EXPECT 0
        (SELECT COUNT(*) FROM sys.database_scoped_credentials
         WHERE name LIKE N'https://%.blob.core.windows.net/%') AS blob_credentials;    -- 1 if kept
GO
