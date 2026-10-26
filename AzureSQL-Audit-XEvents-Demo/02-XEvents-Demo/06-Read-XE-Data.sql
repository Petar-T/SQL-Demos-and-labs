/*==============================================================================
  XEvents DEMO - STEP 4 & 5 : READ THE DATA
  File : 06-Read-XE-Data.sql
  Run  : in the USER database where the sessions run.

  BEFORE YOU RUN
    Ctrl+H -> replace <ContainerUrl> (sections 3c, 5, 6, 6b) with your
    confirmed URL: https://<storage-account>.blob.core.windows.net/xevents

  Every section is standalone: highlight it and press F5.

    0   Session status, dropped events, target fill level      (health)
    1   Ring buffer - generic shredder (@SessionName)           (live view)
    2   Errors summary by error_number                          (Scenario A)
    2b  Lock waits = blocking                                   (Scenario C)
    3   Deadlock graphs - ring buffer (3a/3b), 3c event_file    (Scenario B)
    4   Histogram: slow executions per query_hash + Query Store (Scenario D)
    5   event_file history - generic, 5b current file only      (durable)
    6   Slow queries top N from event_file, 6b blocking from file

  Two ways to read:
    ring_buffer  instant, in memory, no storage round-trip, lost on STOP /
                 failover. The reliable "live" view in Azure SQL Database.
    event_file   .xel blobs in Azure Storage; survives stop / failover.
                 fn_xe_file_target_read_file downloads and parses every blob
                 whose name starts with the supplied prefix - keep it narrow.
                 Azure blob paths use PREFIXES, not '*' wildcards. Read with
                 <ContainerUrl>/demo_xe_errors_deadlocks (no '*' or extension);
                 CREATE target filenames still end in .xel.
  UNITS: batch/rpc duration & cpu_time = MICROseconds; wait duration = MILLIseconds.
  Identity context is the captured sqlserver.username action. Do not substitute
  sqlserver.server_principal_name (unsupported in the tested Azure SQL Database)
  or claim username necessarily identifies the original login after impersonation.
==============================================================================*/
SET NOCOUNT ON;
GO

/*==============================================================================
  0. SESSION HEALTH
  WHAT   Is the session running, and is it LOSING events?
  SAY    "ALLOW_SINGLE_EVENT_LOSS means XE will never slow down your workload
         to save an event - so you must check that it isn't dropping any."
  EXPECT state = RUNNING, dropped_event_count = 0, dropped_buffer_count = 0,
         verdict = Healthy.
==============================================================================*/
SELECT  s.name                                                   AS session_name,
        CASE WHEN r.name IS NULL THEN 'STOPPED' ELSE 'RUNNING' END AS state,
        r.create_time                                            AS running_since_utc,
        r.dropped_event_count,
        r.dropped_buffer_count,
        r.blocked_event_fire_time,
        s.event_retention_mode_desc,
        s.max_dispatch_latency                                   AS dispatch_latency_ms,
        CASE WHEN r.name IS NULL                 THEN 'NOT RUNNING - nothing captured'
             WHEN r.blocked_event_fire_time > 0  THEN 'Session is slowing the workload'
             WHEN r.dropped_buffer_count    > 0  THEN 'Dropping buffers - raise MAX_MEMORY'
             WHEN r.dropped_event_count     > 0  THEN 'Dropping events - tighten predicates'
             ELSE 'Healthy' END                                  AS verdict
FROM    sys.database_event_sessions   AS s
LEFT JOIN sys.dm_xe_database_sessions AS r ON r.name = s.name
WHERE   s.name LIKE N'demo[_]xe[_]%'
ORDER BY s.name;

-- 0b. Targets: ring buffer fill level and the CURRENT .xel blob name.
SELECT  s.name                                   AS session_name,
        t.target_name,
        t.execution_count,
        CASE WHEN t.target_name = N'ring_buffer'
             THEN x.d.value('(RingBufferTarget/@eventCount)[1]', 'int') END           AS rb_events_now,
        CASE WHEN t.target_name = N'ring_buffer'
             THEN x.d.value('(RingBufferTarget/@totalEventsProcessed)[1]', 'int') END AS rb_events_total,
        CASE WHEN t.target_name = N'ring_buffer'
             THEN x.d.value('(RingBufferTarget/@droppedCount)[1]', 'int') END         AS rb_dropped,
        CASE WHEN t.target_name = N'event_file'
             THEN x.d.value('(EventFileTarget/File/@name)[1]', 'nvarchar(1000)') END  AS current_xel_blob
FROM    sys.dm_xe_database_session_targets AS t
JOIN    sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
CROSS APPLY (SELECT CAST(t.target_data AS xml)) AS x(d)
WHERE   s.name LIKE N'demo[_]xe[_]%'
ORDER BY s.name, t.target_name;
GO


/*==============================================================================
  1. RING BUFFER - GENERIC SHREDDER  (the "live view")
  WHAT   Turns the ring buffer XML into rows. Works for all three sessions:
         change @SessionName only.
  SAY    "SSMS 'Watch Live Data' depends on your SSMS version for Azure SQL
         Database - this query always works, from any tool."
  EXPECT demo_xe_errors_deadlocks -> error_reported rows (8134, 208, 245,
         2627, 50000, 1205), attention row(s), database_xml_deadlock_report.
         Click raw_event to see every field the event captured.
==============================================================================*/
DECLARE @SessionName sysname = N'demo_xe_errors_deadlocks';
--      @SessionName sysname = N'demo_xe_slow_queries';
--      @SessionName sysname = N'demo_xe_blocking';

DECLARE @rb xml =
(
    SELECT CAST(t.target_data AS xml)
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = @SessionName
      AND  t.target_name = N'ring_buffer'
);

IF @rb IS NULL
    PRINT N'No ring_buffer found for ' + @SessionName + N' - is the session RUNNING?';

SELECT  ev.value('@timestamp', 'datetime2(3)')                                        AS event_time_utc,
        ev.value('@name', 'sysname')                                                  AS event_name,
        ev.value('(action[@name="session_id"]/value)[1]', 'int')                      AS session_id,
        ev.value('(action[@name="username"]/value)[1]', 'sysname')                    AS username,
        ev.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')       AS client_app,
        ev.value('(action[@name="client_hostname"]/value)[1]', 'nvarchar(256)')       AS client_host,
        ev.value('(data[@name="error_number"]/value)[1]', 'int')                      AS error_number,
        ev.value('(data[@name="severity"]/value)[1]', 'int')                          AS severity,
        ev.value('(data[@name="message"]/value)[1]', 'nvarchar(2048)')                AS message,
        ev.value('(data[@name="wait_type"]/text)[1]', 'nvarchar(128)')                AS wait_type,
        -- normalise duration to milliseconds: wait events are already ms,
        -- batch / rpc events are microseconds
        CASE WHEN ev.value('@name', 'sysname') = N'wait_completed'
             THEN ev.value('(data[@name="duration"]/value)[1]', 'bigint')
             ELSE ev.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000
        END                                                                           AS duration_ms,
        ev.value('(data[@name="cpu_time"]/value)[1]', 'bigint') / 1000                AS cpu_ms,
        ev.value('(data[@name="logical_reads"]/value)[1]', 'bigint')                  AS logical_reads,
        COALESCE(ev.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)'),
                 ev.value('(data[@name="batch_text"]/value)[1]', 'nvarchar(max)'),
                 ev.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)'))     AS sql_text,
        ev.value('(action[@name="query_hash"]/value)[1]', 'decimal(20,0)')            AS query_hash_uint64,
        ev.query('.')                                                                 AS raw_event
FROM    @rb.nodes('/RingBufferTarget/event') AS q(ev)
ORDER BY event_time_utc DESC;
GO


/*==============================================================================
  2. ERRORS SUMMARY  (Scenario A)
  WHAT   Group the error_reported events: which errors, how often, from where.
  SAY    "This is your 'top errors' report - per error number, with the last
         statement and the app that caused it."
  EXPECT One row each for 8134, 208, 245, 2627, 50000 (+1205 after Scenario B),
         and an 'ATTENTION' row for the cancelled query.
==============================================================================*/
DECLARE @rb xml =
(
    SELECT CAST(t.target_data AS xml)
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = N'demo_xe_errors_deadlocks'
      AND  t.target_name = N'ring_buffer'
);

WITH e AS
(
    SELECT  ev.value('@timestamp', 'datetime2(3)')                                  AS event_time_utc,
            ev.value('@name', 'sysname')                                            AS event_name,
            ev.value('(data[@name="error_number"]/value)[1]', 'int')                AS error_number,
            ev.value('(data[@name="severity"]/value)[1]', 'int')                    AS severity,
            ev.value('(data[@name="message"]/value)[1]', 'nvarchar(2048)')          AS message,
            ev.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app,
            ev.value('(action[@name="username"]/value)[1]', 'sysname')              AS username,
            ev.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')        AS sql_text
    FROM    @rb.nodes('/RingBufferTarget/event[@name="error_reported" or @name="attention"]') AS q(ev)
)
SELECT  CASE WHEN event_name = N'attention' THEN 'ATTENTION (client cancel / timeout)'
             ELSE CAST(error_number AS varchar(12)) END  AS error_or_event,
        MAX(severity)                                    AS severity,
        COUNT(*)                                         AS occurrences,
        MIN(event_time_utc)                              AS first_seen_utc,
        MAX(event_time_utc)                              AS last_seen_utc,
        MAX(message)                                     AS sample_message,
        MAX(client_app)                                  AS sample_app,
        MAX(username)                                    AS sample_user,
        MAX(LEFT(sql_text, 400))                         AS sample_sql
FROM    e
GROUP BY CASE WHEN event_name = N'attention' THEN 'ATTENTION (client cancel / timeout)'
              ELSE CAST(error_number AS varchar(12)) END
ORDER BY occurrences DESC, error_or_event;
GO


/*==============================================================================
  2b. BLOCKING = LONG LOCK WAITS  (Scenario C)
  WHAT   wait_completed events from demo_xe_blocking, keeping LCK_M_* waits
         and the verified optimized-locking transaction-resource waits
         XACT_WITH_RESOURCE_TO_READ / XACT_WITH_RESOURCE_TO_MODIFY.
         The session itself only filters on duration > 2 s.
  SAY    "This is the BLOCKED side: who waited, how long, on what statement.
         The blocker is the session that held the lock - for live blocking
         chains use sys.dm_exec_requests.blocking_session_id."
  EXPECT The blocking reader's LCK_M_* or XACT_WITH_RESOURCE_TO_READ wait,
         duration_ms ~ the time until ROLLBACK and its waiting SQL text.
         The rehearsal observed XACT_WITH_RESOURCE_TO_READ ~16781 ms and
         XACT_WITH_RESOURCE_TO_MODIFY from writer/deadlock scenarios.
         WAITFOR is deliberately excluded; do not classify all waits as blocking.
==============================================================================*/
DECLARE @rb xml =
(
    SELECT CAST(t.target_data AS xml)
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = N'demo_xe_blocking'
      AND  t.target_name = N'ring_buffer'
);

WITH w AS
(
    SELECT  ev.value('@timestamp', 'datetime2(3)')                                  AS event_time_utc,
            ev.value('@name', 'sysname')                                            AS event_name,
            ev.value('(data[@name="wait_type"]/text)[1]', 'nvarchar(128)')          AS wait_type,
            ev.value('(data[@name="duration"]/value)[1]', 'bigint')                 AS duration_ms,   -- already ms
            ev.value('(data[@name="signal_duration"]/value)[1]', 'bigint')          AS signal_ms,
            ev.value('(action[@name="session_id"]/value)[1]', 'int')                AS waiting_session_id,
            ev.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app,
            ev.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')        AS waiting_sql
    FROM    @rb.nodes('/RingBufferTarget/event') AS q(ev)
)
SELECT  *
FROM    w
WHERE   wait_type LIKE N'LCK[_]M[_]%'
   OR   wait_type IN (N'XACT_WITH_RESOURCE_TO_READ', N'XACT_WITH_RESOURCE_TO_MODIFY')
   OR   event_name = N'lock_escalation'
ORDER BY event_time_utc DESC;
GO


/*==============================================================================
  3. DEADLOCK GRAPHS - FROM THE RING BUFFER  (Scenario B)
  WHAT   One row per deadlock with the full graph as clickable XML, then one
         row per participating process.
  SAY    "Click the XML. File > Save As... > Save as type: All Files >
         name it deadlock.xdl. Re-open the .xdl in SSMS and you get the
         graphical deadlock graph - the victim has a blue X."
  EXPECT 1 row per deadlock, process_count = 2. Second result set: 2 rows,
         one is_victim = 1, inputbuf = the two UPDATE statements.
  NOTE   Database names show as a GUID (physical_database_name) in Azure SQL
         Database deadlock graphs - that's expected.
==============================================================================*/
DECLARE @rb xml =
(
    SELECT CAST(t.target_data AS xml)
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = N'demo_xe_errors_deadlocks'
      AND  t.target_name = N'ring_buffer'
);

DECLARE @dl TABLE (deadlock_time_utc datetime2(3), deadlock_graph xml);

INSERT INTO @dl (deadlock_time_utc, deadlock_graph)
SELECT  ev.value('@timestamp', 'datetime2(3)'),
        ev.query('(data[@name="xml_report"]/value/deadlock)[1]')
FROM    @rb.nodes('/RingBufferTarget/event[@name="database_xml_deadlock_report"]') AS q(ev);

-- 3a. One row per deadlock -> click deadlock_graph, save as .xdl
SELECT  deadlock_time_utc,
        deadlock_graph.value('(deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(100)') AS victim_process_id,
        deadlock_graph.value('count(deadlock/process-list/process)', 'int')                  AS process_count,
        deadlock_graph
FROM    @dl
ORDER BY deadlock_time_utc DESC;

-- 3b. One row per process in each deadlock
SELECT  d.deadlock_time_utc,
        p.pr.value('@spid', 'int')                                     AS session_id,
        CASE WHEN p.pr.value('@id', 'nvarchar(100)') =
                  d.deadlock_graph.value('(deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(100)')
             THEN 1 ELSE 0 END                                         AS is_victim,
        p.pr.value('@clientapp', 'nvarchar(256)')                      AS client_app,
        p.pr.value('@hostname', 'nvarchar(256)')                       AS client_host,
        p.pr.value('@loginname', 'nvarchar(256)')                      AS login_name,
        p.pr.value('@isolationlevel', 'nvarchar(100)')                 AS isolation_level,
        p.pr.value('@waitresource', 'nvarchar(256)')                   AS wait_resource,
        p.pr.value('@lockMode', 'nvarchar(20)')                        AS lock_mode_requested,
        p.pr.value('(executionStack/frame/@queryhash)[1]', 'nvarchar(50)') AS query_hash_hex,
        LTRIM(RTRIM(p.pr.value('(inputbuf)[1]', 'nvarchar(4000)')))    AS input_buffer
FROM    @dl AS d
CROSS APPLY d.deadlock_graph.nodes('deadlock/process-list/process') AS p(pr)
ORDER BY d.deadlock_time_utc DESC, is_victim DESC;
GO

/*------------------------------------------------------------------------------
  3c. DEADLOCK GRAPHS - FROM THE EVENT FILE (durable; survives STOP/failover)
      Replace <ContainerUrl>. Same click-and-save-as-.xdl trick.
      Never point this at the built-in 'dl' session's files.
------------------------------------------------------------------------------*/
SELECT  x.ev.value('@timestamp', 'datetime2(3)')                              AS deadlock_time_utc,
        x.ev.query('(data[@name="xml_report"]/value/deadlock)[1]')            AS deadlock_graph,
        f.file_name                                                           AS source_blob
FROM    sys.fn_xe_file_target_read_file(
            N'<ContainerUrl>/demo_xe_errors_deadlocks', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS d(x)
CROSS APPLY d.x.nodes('/event[@name="database_xml_deadlock_report"]') AS x(ev)
ORDER BY deadlock_time_utc DESC;
GO


/*==============================================================================
  4. HISTOGRAM - SLOW EXECUTIONS PER query_hash  (Scenario D)
  WHAT   Read the in-memory histogram target and look each hash up in
         Query Store to get the query text and query_id.
  SAY    "The engine counted slow batch events by the captured hash.
         A meaningful nonzero query_hash may connect to Query Store."
  EXPECT Actual buckets only; this rehearsal produced one bucket, not three
         proven query shapes. Batch-level query_hash can be zero/unavailable,
         so different workloads can collapse into one bucket.
         Query Store text/ID appear only for hashes it captured and that match.

  HASH CONVERSION (why it's not a simple CAST):
    XE query_hash action  = UNSIGNED 64-bit number, e.g. 17256289371029481234
    Query Store query_hash = binary(8), e.g. 0xEF7A0A9B5C3D2E11
    Method: if > 2^63-1 subtract 2^64 (unsigned -> signed two's complement),
    CAST to bigint, then CONVERT to binary(8) (big-endian bytes).
    Spot-check on stage: the hex value should also match the 'queryhash'
    attribute in deadlock graphs / sys.dm_exec_query_stats.query_hash.
    If a hash doesn't join, compare query_hash_uint64 / query_hash_binary
    manually - the raw value is always shown.
==============================================================================*/
DECLARE @h xml =
(
    SELECT CAST(t.target_data AS xml)
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = N'demo_xe_slow_queries'
      AND  t.target_name = N'histogram'
);

WITH buckets AS
(
    SELECT  sl.value('(value)[1]', 'decimal(20,0)') AS query_hash_uint64,
            sl.value('@count', 'bigint')            AS slow_executions
    FROM    @h.nodes('/HistogramTarget/Slot') AS q(sl)
),
hashed AS
(
    SELECT  b.query_hash_uint64,
            b.slow_executions,
            CONVERT(binary(8),
                CONVERT(bigint,
                    CASE WHEN b.query_hash_uint64 > 9223372036854775807
                         THEN b.query_hash_uint64 - 18446744073709551616
                         ELSE b.query_hash_uint64 END)) AS query_hash_binary
    FROM    buckets AS b
)
SELECT  h.slow_executions,
        h.query_hash_uint64,
        h.query_hash_binary,
        qsq.query_id                         AS query_store_query_id,
        LEFT(qst.query_sql_text, 300)        AS query_text
FROM    hashed AS h
LEFT JOIN sys.query_store_query      AS qsq ON qsq.query_hash    = h.query_hash_binary
LEFT JOIN sys.query_store_query_text AS qst ON qst.query_text_id = qsq.query_text_id
ORDER BY h.slow_executions DESC, h.query_hash_uint64;
GO


/*==============================================================================
  5. EVENT FILE - HISTORY FROM BLOB STORAGE  (generic)
  WHAT   Read durable .xel blobs using a per-session Azure blob PREFIX, without
         '*' or an extension. The prefix includes all rollover files for that
         session (XE adds a numeric suffix to the target filename).
  SAY    "The ring buffer is gone after a STOP or failover - the blob isn't.
         This is what you keep for the post-mortem."
  EXPECT Same events as section 1, plus source_blob / file_offset columns.
         Five-second MAX_DISPATCH_LATENCY requests dispatch frequency;
         allow additional storage write/read time and verify actual delivery.
  NOTE   SSMS 19.2+ can also open the session's event_file directly from
         Object Explorer (it reads the blobs from the container).
==============================================================================*/
SELECT  x.ev.value('@timestamp', 'datetime2(3)')                                    AS event_time_utc,
        x.ev.value('@name', 'sysname')                                              AS event_name,
        x.ev.value('(data[@name="error_number"]/value)[1]', 'int')                  AS error_number,
        x.ev.value('(data[@name="severity"]/value)[1]', 'int')                      AS severity,
        x.ev.value('(data[@name="message"]/value)[1]', 'nvarchar(2048)')            AS message,
        x.ev.value('(action[@name="username"]/value)[1]', 'sysname')                AS username,
        x.ev.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')   AS client_app,
        x.ev.value('(action[@name="client_hostname"]/value)[1]', 'nvarchar(256)')   AS client_host,
        x.ev.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')          AS sql_text,
        f.file_name                                                                 AS source_blob,
        f.file_offset
FROM    sys.fn_xe_file_target_read_file(
            N'<ContainerUrl>/demo_xe_errors_deadlocks', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS d(x)
CROSS APPLY d.x.nodes('/event') AS x(ev)
ORDER BY event_time_utc DESC;
GO

/*------------------------------------------------------------------------------
  5b. EXACT CURRENT BLOB - an alternative to reading every rollover blob
      matched by section 5's prefix, not a workaround for a wildcard error.
      It reads only the current file and can omit earlier rollover history.
      No placeholder needed - the file name comes from the running session.
------------------------------------------------------------------------------*/
DECLARE @current_file nvarchar(1000) =
(
    SELECT CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(1000)')
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = N'demo_xe_errors_deadlocks'
      AND  t.target_name = N'event_file'
);

SELECT @current_file AS current_blob;

SELECT  x.ev.value('@timestamp', 'datetime2(3)')                           AS event_time_utc,
        x.ev.value('@name', 'sysname')                                     AS event_name,
        x.ev.value('(data[@name="error_number"]/value)[1]', 'int')         AS error_number,
        x.ev.value('(data[@name="message"]/value)[1]', 'nvarchar(2048)')   AS message,
        x.ev.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
        x.ev.query('.')                                                    AS raw_event
FROM    sys.fn_xe_file_target_read_file(@current_file, NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS d(x)
CROSS APPLY d.x.nodes('/event') AS x(ev)
ORDER BY event_time_utc DESC;
GO


/*==============================================================================
  6. SLOW QUERIES - TOP N BY TOTAL DURATION, FROM THE EVENT FILE  (Scenario D)
  WHAT   Aggregate every slow execution in the blobs per query_hash.
  SAY    "Look at duration vs CPU: when they're equal the query is burning
         CPU (fix the plan / index). When duration >> CPU it was WAITING
         (blocking, IO, WAITFOR) - go to the blocking session."
  EXPECT D1 / D2 / D3 shapes with avg_cpu_ms ~= avg_duration_ms;
         WAITFOR and deadlock/blocking batches with cpu ~ 0.
==============================================================================*/
WITH raw AS
(
    SELECT  x.ev.value('@timestamp', 'datetime2(3)')                                   AS event_time_utc,
            x.ev.value('@name', 'sysname')                                             AS event_name,
            x.ev.value('(action[@name="query_hash"]/value)[1]', 'decimal(20,0)')       AS query_hash_uint64,
            x.ev.value('(data[@name="duration"]/value)[1]', 'bigint')                  AS duration_us,
            x.ev.value('(data[@name="cpu_time"]/value)[1]', 'bigint')                  AS cpu_us,
            x.ev.value('(data[@name="logical_reads"]/value)[1]', 'bigint')             AS logical_reads,
            x.ev.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')  AS client_app,
            COALESCE(x.ev.value('(data[@name="batch_text"]/value)[1]', 'nvarchar(max)'),
                     x.ev.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)'),
                     x.ev.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')) AS sql_text
    FROM    sys.fn_xe_file_target_read_file(
                N'<ContainerUrl>/demo_xe_slow_queries', NULL, NULL, NULL) AS f
    CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS d(x)
    CROSS APPLY d.x.nodes('/event') AS x(ev)
)
SELECT TOP (10)
        query_hash_uint64,
        COUNT(*)                          AS executions,
        SUM(duration_us) / 1000           AS total_duration_ms,
        AVG(duration_us) / 1000           AS avg_duration_ms,
        MAX(duration_us) / 1000           AS max_duration_ms,
        AVG(cpu_us)      / 1000           AS avg_cpu_ms,
        AVG(logical_reads)                AS avg_logical_reads,
        MAX(client_app)                   AS sample_app,
        MAX(LEFT(sql_text, 300))          AS sample_sql,
        MAX(event_time_utc)               AS last_seen_utc
FROM    raw
GROUP BY query_hash_uint64
ORDER BY total_duration_ms DESC;
GO

/*------------------------------------------------------------------------------
  6b. BLOCKING HISTORY FROM THE EVENT FILE (verified locking-wait families only)
------------------------------------------------------------------------------*/
SELECT  x.ev.value('@timestamp', 'datetime2(3)')                                  AS event_time_utc,
        x.ev.value('(data[@name="wait_type"]/text)[1]', 'nvarchar(128)')          AS wait_type,
        x.ev.value('(data[@name="duration"]/value)[1]', 'bigint')                 AS duration_ms,
        x.ev.value('(action[@name="session_id"]/value)[1]', 'int')                AS waiting_session_id,
        x.ev.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app,
        x.ev.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')        AS waiting_sql
FROM    sys.fn_xe_file_target_read_file(
            N'<ContainerUrl>/demo_xe_blocking', NULL, NULL, NULL) AS f
CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS d(x)
CROSS APPLY d.x.nodes('/event[@name="wait_completed"]') AS x(ev)
WHERE   x.ev.value('(data[@name="wait_type"]/text)[1]', 'nvarchar(128)') LIKE N'LCK[_]M[_]%'
   OR   x.ev.value('(data[@name="wait_type"]/text)[1]', 'nvarchar(128)')
        IN (N'XACT_WITH_RESOURCE_TO_READ', N'XACT_WITH_RESOURCE_TO_MODIFY')
ORDER BY event_time_utc DESC;
GO
