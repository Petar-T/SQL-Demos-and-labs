/*==============================================================================
  XEvents DEMO - STEP 2 : CREATE THE THREE DEMO EVENT SESSIONS
  File : 03-Create-XE-Sessions.sql
  Run  : in the USER database (same database as 02-Create-Credential.sql).
  Needs: ALTER ANY DATABASE EVENT SESSION (db_owner has it).

  BEFORE YOU RUN
    Ctrl+H  ->  replace  <ContainerUrl>  with your container URL, e.g.
        https://<storage-account>.blob.core.windows.net/xevents
    It must be EXACTLY the name of the credential created in step 1.

  THE THREE SESSIONS (all: ON DATABASE, STARTUP_STATE = OFF -> demo / ad hoc)
    demo_xe_errors_deadlocks  error_reported (sev >= 11), attention,
                              database_xml_deadlock_report
    demo_xe_slow_queries      sql_batch_completed / rpc_completed > 1 s
                              + histogram target bucketed by query_hash
    demo_xe_blocking          sqlos.wait_completed > 2000 ms (lock waits),
                              lock_escalation

  Every session has two (or three) targets:
    ring_buffer  -> in memory, instant, "live view"; lost when session stops
    event_file   -> .xel blobs in Azure Storage, durable history
    histogram    -> (slow queries only) in-memory counts per query_hash

  UNITS (the #1 XE mistake):
    sql_batch_completed / rpc_completed : duration, cpu_time in MICROseconds
    sqlos.wait_completed                : duration in MILLIseconds

  For an always-on production set (STARTUP_STATE = ON, more events, file
  rotation, health procedures) use the production toolkit:
    AzureSQL-Observability/02-xevents  (10-13-xe-*.sql, 20-, 30-)
==============================================================================*/
SET NOCOUNT ON;
GO

/*==============================================================================
  2.0 PRE-FLIGHT
  WHAT   Check database/credential and inspect every required event, action,
         target and predicate source before replacing existing sessions.
  EXPECT current_database = your user DB, credential_found = 1,
         19 required objects marked available (7 events, 8 actions,
         3 targets and 1 predicate source). DDL remains the final runtime test.
==============================================================================*/
SELECT  DB_NAME() AS current_database,
        (SELECT COUNT(*) FROM sys.database_scoped_credentials
         WHERE name = N'<ContainerUrl>') AS credential_found;   -- EXPECT 1

DECLARE @Required TABLE
(
    package_name sysname,
    object_type nvarchar(60),
    object_name sysname
);
INSERT INTO @Required VALUES
    (N'sqlserver', N'event', N'error_reported'),
    (N'sqlserver', N'event', N'attention'),
    (N'sqlserver', N'event', N'database_xml_deadlock_report'),
    (N'sqlserver', N'event', N'sql_batch_completed'),
    (N'sqlserver', N'event', N'rpc_completed'),
    (N'sqlos', N'event', N'wait_completed'),
    (N'sqlserver', N'event', N'lock_escalation'),
    (N'sqlserver', N'action', N'sql_text'),
    (N'sqlserver', N'action', N'client_app_name'),
    (N'sqlserver', N'action', N'client_hostname'),
    (N'sqlserver', N'action', N'username'),
    (N'sqlserver', N'action', N'session_id'),
    (N'sqlserver', N'action', N'database_name'),
    (N'sqlserver', N'action', N'query_hash'),
    (N'sqlserver', N'action', N'query_plan_hash'),
    (N'package0', N'target', N'ring_buffer'),
    (N'package0', N'target', N'event_file'),
    (N'package0', N'target', N'histogram'),
    (N'sqlserver', N'pred_source', N'is_system');

;WITH AvailableObjects AS
(
    SELECT p.name AS package_name,
           o.object_type,
           o.name AS object_name,
           o.capabilities_desc,
           o.description,
           ROW_NUMBER() OVER
           (
               PARTITION BY p.name, o.object_type, o.name
               ORDER BY p.guid
           ) AS match_rank
    FROM sys.dm_xe_packages AS p
    JOIN sys.dm_xe_objects AS o ON o.package_guid = p.guid
)
SELECT r.package_name + N'.' + r.object_name AS required_object,
       r.object_type,
       CONVERT(bit, CASE WHEN o.object_name IS NULL THEN 0 ELSE 1 END) AS available,
       o.capabilities_desc,
       o.description
FROM @Required AS r
LEFT JOIN AvailableObjects AS o
    ON o.package_name = r.package_name
   AND o.object_type = r.object_type
   AND o.object_name = r.object_name
   AND o.match_rank = 1
ORDER BY r.object_type, required_object;

IF DB_NAME() <> N'sqldb-auditdemo'
   OR NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'<ContainerUrl>')
   OR EXISTS
      (SELECT 1
       FROM @Required AS r
       WHERE NOT EXISTS
          (SELECT 1
           FROM sys.dm_xe_objects AS o
           JOIN sys.dm_xe_packages AS p ON p.guid = o.package_guid
           WHERE p.name = r.package_name
             AND o.object_type = r.object_type
             AND o.name = r.object_name))
BEGIN
    SET NOEXEC ON; -- Do not drop/recreate sessions after a failed preflight.
    THROW 50000, 'XE preflight failed: inspect database, credential and required-object metadata before continuing.', 1;
END;
GO


/*==============================================================================
  2a. demo_xe_errors_deadlocks
  WHAT   Errors the user saw, client cancels/timeouts (attention) and the
         full deadlock graph - the "what went wrong, and with which statement"
         session. Fires only on failure -> cheap enough to leave on.
  SAY    "Auditing tells you WHO ran a statement. This tells you the statement
         FAILED, with which error, from which app and host."
  NOTE   Noise filter (same as production toolkit 11-xe-errors-deadlocks.sql):
           3621 = 'The statement has been terminated' (always paired with
                  the real error)
           5701 / 5703 = database / language context change messages
           2528 = DBCC execution completed
         XE predicates do not support IN (...) -> written as AND chains.
         Deadlocks are captured with our OWN session using
         sqlserver.database_xml_deadlock_report. Never read the built-in
         'dl' session in Azure SQL Database (can cause OOM in master).
==============================================================================*/
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'demo_xe_errors_deadlocks')
    DROP EVENT SESSION [demo_xe_errors_deadlocks] ON DATABASE;
GO

CREATE EVENT SESSION [demo_xe_errors_deadlocks] ON DATABASE

ADD EVENT sqlserver.error_reported (
    ACTION (sqlserver.sql_text,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.username,
            sqlserver.session_id,
            sqlserver.database_name,
            sqlserver.query_hash)
    WHERE ( [severity] >= (11)
        AND [error_number] <> (3621)
        AND [error_number] <> (5701)
        AND [error_number] <> (5703)
        AND [error_number] <> (2528) ) ),

ADD EVENT sqlserver.attention (
    ACTION (sqlserver.sql_text,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.username,
            sqlserver.session_id,
            sqlserver.database_name,
            sqlserver.query_hash) ),

-- The deadlock monitor raises this event from a background task, so client
-- actions would be empty. Everything you need is inside the xml_report field.
ADD EVENT sqlserver.database_xml_deadlock_report

ADD TARGET package0.ring_buffer (
    SET max_memory       = (1024),      -- KB
        max_events_limit = (1000) ),

ADD TARGET package0.event_file (
    SET filename           = N'<ContainerUrl>/demo_xe_errors_deadlocks.xel',
        max_file_size      = (10),      -- MB per file
        max_rollover_files = (5) )

WITH ( MAX_MEMORY            = 4096 KB,
       EVENT_RETENTION_MODE  = ALLOW_SINGLE_EVENT_LOSS,
       MAX_DISPATCH_LATENCY  = 5 SECONDS,
       MAX_EVENT_SIZE        = 0 KB,
       MEMORY_PARTITION_MODE = NONE,
       TRACK_CAUSALITY       = OFF,
       STARTUP_STATE         = OFF );   -- demo: ad hoc. Production: ON
GO


/*==============================================================================
  2b. demo_xe_slow_queries
  WHAT   Every batch (SSMS, ad hoc) or RPC (application, parameterised call)
         that runs longer than 1 second, plus a HISTOGRAM target that counts
         slow executions per query_hash - "which query SHAPE hurts most".
  SAY    "Query Store gives you aggregates. XE gives you the single slow
         execution: exact text, app, host, user, CPU vs. duration."
  NOTE   duration > 1000000 = 1,000,000 MICROseconds = 1 second.
         Histogram rules:
           filtering_event_name = the ONE event the histogram listens to
           source               = the field/action to bucket by
           source_type          = 0 -> event data field, 1 -> action
         The action used as source MUST also be in the event's ACTION list.
         Meaningful statement hashes can group literal variants, but the
         batch-level action may be zero/unavailable. Do not assume one distinct
         histogram bucket per workload or a successful Query Store join.
==============================================================================*/
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'demo_xe_slow_queries')
    DROP EVENT SESSION [demo_xe_slow_queries] ON DATABASE;
GO

CREATE EVENT SESSION [demo_xe_slow_queries] ON DATABASE

ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.username,
            sqlserver.session_id,
            sqlserver.database_name,
            sqlserver.query_hash,
            sqlserver.query_plan_hash)
    WHERE ( [duration] > (1000000)               -- microseconds = 1 s
        AND [sqlserver].[is_system] = (0) ) ),

ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.sql_text,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.username,
            sqlserver.session_id,
            sqlserver.database_name,
            sqlserver.query_hash,
            sqlserver.query_plan_hash)
    WHERE ( [duration] > (1000000)               -- microseconds = 1 s
        AND [sqlserver].[is_system] = (0) ) )

ADD TARGET package0.ring_buffer (
    SET max_memory       = (1024),
        max_events_limit = (500) ),

ADD TARGET package0.event_file (
    SET filename           = N'<ContainerUrl>/demo_xe_slow_queries.xel',
        max_file_size      = (20),
        max_rollover_files = (5) ),

ADD TARGET package0.histogram (
    SET filtering_event_name = N'sqlserver.sql_batch_completed',
        source               = N'sqlserver.query_hash',
        source_type          = (1),              -- 1 = action
        slots                = (64) )

WITH ( MAX_MEMORY            = 4096 KB,
       EVENT_RETENTION_MODE  = ALLOW_SINGLE_EVENT_LOSS,
       MAX_DISPATCH_LATENCY  = 5 SECONDS,
       MAX_EVENT_SIZE        = 0 KB,
       MEMORY_PARTITION_MODE = NONE,
       TRACK_CAUSALITY       = OFF,
       STARTUP_STATE         = OFF );   -- the expensive one: run in bursts only
GO


/*==============================================================================
  2c. demo_xe_blocking
  WHAT   Long waits (> 2 s) by user sessions. Lock waits (LCK_M_*) = blocking.
         Replaces blocked_process_report, which can't be used in Azure SQL
         Database because 'blocked process threshold' (sp_configure) is not
         available.
  SAY    "The event fires when the wait COMPLETES - so you see the victim of
         blocking, how long it waited, and on which statement."
  NOTE   Same predicate approach as production toolkit 13-xe-blocking-waits.sql:
         filter on duration + is_system only, and select verified locking waits when
         READING (06-Read-XE-Data.sql). Reason: wait_type is a map field and the
         numeric map keys differ between engine versions (optimized locking
         expose XACT_WITH_RESOURCE_TO_READ / XACT_WITH_RESOURCE_TO_MODIFY),
         so hard-coding numeric key ranges is fragile. The readers retain
         LCK_M_* and these two verified exact transaction-resource wait names.
         Side effect: WAITFOR DELAY > 2 s also shows up (wait_type WAITFOR).
         duration > 2000 = 2000 MILLIseconds = 2 s.
         Optional: to filter lock waits in the session itself, look up the keys
         first and add  AND ([wait_type] = (<key>) OR ...)  :
           SELECT map_key, map_value FROM sys.dm_xe_map_values
           WHERE name = N'wait_types'
             AND (map_value LIKE N'LCK[_]M[_]%'
                  OR map_value IN (N'XACT_WITH_RESOURCE_TO_READ',
                                   N'XACT_WITH_RESOURCE_TO_MODIFY'));
         lock_escalation: optimized locking (always on in Azure SQL DB) makes
         escalation rare - included so the audience knows it exists.
==============================================================================*/
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'demo_xe_blocking')
    DROP EVENT SESSION [demo_xe_blocking] ON DATABASE;
GO

CREATE EVENT SESSION [demo_xe_blocking] ON DATABASE

ADD EVENT sqlos.wait_completed (
    ACTION (sqlserver.sql_text,
            sqlserver.session_id,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.username,
            sqlserver.database_name,
            sqlserver.query_hash)
    WHERE ( [duration] > (2000)                  -- milliseconds = 2 s
        AND [sqlserver].[is_system] = (0) ) ),

ADD EVENT sqlserver.lock_escalation (
    ACTION (sqlserver.sql_text,
            sqlserver.session_id,
            sqlserver.client_app_name,
            sqlserver.database_name) )

ADD TARGET package0.ring_buffer (
    SET max_memory       = (1024),
        max_events_limit = (1000) ),

ADD TARGET package0.event_file (
    SET filename           = N'<ContainerUrl>/demo_xe_blocking.xel',
        max_file_size      = (10),
        max_rollover_files = (5) )

WITH ( MAX_MEMORY            = 4096 KB,
       EVENT_RETENTION_MODE  = ALLOW_SINGLE_EVENT_LOSS,
       MAX_DISPATCH_LATENCY  = 5 SECONDS,
       MAX_EVENT_SIZE        = 0 KB,
       MEMORY_PARTITION_MODE = NONE,
       TRACK_CAUSALITY       = OFF,
       STARTUP_STATE         = OFF );
GO


/*==============================================================================
  2d. START THE SESSIONS
  WHAT   Creating a session does nothing until it is started. Starting is when
         the engine first talks to Blob Storage - this is where storage /
         credential problems show up.
  EXPECT "Commands completed successfully."
         If START fails, see the README troubleshooting table:
           OS error 86 -> credential name <> container URL (or trailing '/')
           OS error 5  -> managed identity lacks Storage Blob Data Contributor,
                          or storage firewall blocks the server
           OS error 3  -> container does not exist
           OS error 13 -> hierarchical namespace / immutability on storage
  PLAN B If storage is broken during a live demo: remove the
         ADD TARGET package0.event_file (...) block, re-create, start -
         the ring_buffer (and histogram) still work without storage.
==============================================================================*/
ALTER EVENT SESSION [demo_xe_errors_deadlocks] ON DATABASE STATE = START;
GO
ALTER EVENT SESSION [demo_xe_slow_queries]     ON DATABASE STATE = START;
GO
ALTER EVENT SESSION [demo_xe_blocking]         ON DATABASE STATE = START;
GO


/*==============================================================================
  2e. STATUS
  EXPECT 3 rows, state = RUNNING, dropped_event_count = 0.
         In SSMS: Object Explorer > Databases > <your DB> > Extended Events >
         Sessions (press F5/Refresh) - the three demo_xe_* sessions appear.
==============================================================================*/
SELECT  s.name                                                   AS session_name,
        CASE WHEN r.name IS NULL THEN 'STOPPED' ELSE 'RUNNING' END AS state,
        s.startup_state,
        r.create_time                                            AS running_since_utc,
        r.dropped_event_count,
        r.dropped_buffer_count
FROM    sys.database_event_sessions  AS s
LEFT JOIN sys.dm_xe_database_sessions AS r ON r.name = s.name
WHERE   s.name LIKE N'demo[_]xe[_]%'
ORDER BY s.name;

-- Targets per running session. EXPECT event_file + ring_buffer (+ histogram).
SELECT  s.name        AS session_name,
        t.target_name,
        t.execution_count
FROM    sys.dm_xe_database_session_targets AS t
JOIN    sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
WHERE   s.name LIKE N'demo[_]xe[_]%'
ORDER BY s.name, t.target_name;
GO
SET NOEXEC OFF;
GO
