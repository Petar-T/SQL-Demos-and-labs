/*==============================================================================
  XEvents DEMO - SCENARIO D : SLOW QUERIES + HISTOGRAM
  File    : 05f-Scenario-Slow-Queries.sql
  Session : demo_xe_slow_queries  (must be RUNNING)
  Prereq  : 04-Setup-Demo-Objects.sql (xedemo.usp_SlowReport)

  WHAT   Run several workloads, including repeated statements with different literals.
         Each execution > 1 s becomes one sql_batch_completed event; the
        histogram target counts captured sql_batch_completed events by query_hash.
  SAY    "Inspect the actual captured hash before interpreting a bucket as a
        query shape. Batch-level query_hash can be zero or unavailable."
  EXPECT ~1-5 s per batch (tune @Multiplier / TOP if a batch is < 1 s).
         06-Read-XE-Data.sql section 4 (histogram):
           actual buckets only; the rehearsal produced one bucket. No promise
           of separate D1/D2/D3 hashes or exactly three events per bucket.
           A zero hash cannot identify a query shape or support a reliable
           Query Store lookup.
         Section 6 (event file): duration vs cpu_time per query_hash.
         Note: the deadlock / blocking / WAITFOR batches from other scenarios
         also ran > 1 s, so they appear here as well - that's correct.
  TIP    Each statement below is its own batch, but that does not guarantee
        a meaningful batch-level query_hash. "GO 3" = run batch 3x.
==============================================================================*/
SET NOCOUNT ON;
GO

/*------------------------------------------------------------------------------
  D1. CPU-heavy ad hoc query - same shape, three different literals.
      EXPECT duration ~= cpu_time (CPU-bound).
------------------------------------------------------------------------------*/
SELECT COUNT_BIG(*) AS combos FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
CROSS JOIN (SELECT TOP (8)  1 AS n FROM sys.all_objects) AS m WHERE a.object_id <> 1 OPTION (MAXDOP 1);
GO
SELECT COUNT_BIG(*) AS combos FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
CROSS JOIN (SELECT TOP (8)  1 AS n FROM sys.all_objects) AS m WHERE a.object_id <> 2 OPTION (MAXDOP 1);
GO
SELECT COUNT_BIG(*) AS combos FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
CROSS JOIN (SELECT TOP (8)  1 AS n FROM sys.all_objects) AS m WHERE a.object_id <> 3 OPTION (MAXDOP 1);
GO

/*------------------------------------------------------------------------------
  D2. Stored procedure (same text every time) - three executions.
      From SSMS this is a language batch -> sql_batch_completed.
      From an application (parameterised call) it would be rpc_completed.
------------------------------------------------------------------------------*/
EXEC xedemo.usp_SlowReport @Multiplier = 10;
GO 3

/*------------------------------------------------------------------------------
  D3. AdventureWorksLT flavour (only if the SalesLT schema exists, e.g. the
      'sqldb-auditdemo' lab database). Skip on other databases.
      ~295 products x ~850 customers x TOP(n) order lines.
------------------------------------------------------------------------------*/
SELECT p.ProductCategoryID, COUNT_BIG(*) AS combos
FROM   SalesLT.Product  AS p
CROSS JOIN SalesLT.Customer AS c
CROSS JOIN (SELECT TOP (40) SalesOrderDetailID FROM SalesLT.SalesOrderDetail) AS d
WHERE  (p.ProductID + c.CustomerID + d.SalesOrderDetailID) % 7 = 0
GROUP BY p.ProductCategoryID
OPTION (MAXDOP 1);
GO 2

/*------------------------------------------------------------------------------
  D4. Quick fallback: WAITFOR. Registers DURATION (~2,000,000 us) but almost
      zero cpu_time. Great for explaining "slow" vs "busy":
        duration high + cpu low  -> waiting (locks, IO, network, WAITFOR)
        duration ~= cpu          -> burning CPU (plan / indexing problem)
      query_hash may be 0 here: WAITFOR has no query plan.
------------------------------------------------------------------------------*/
WAITFOR DELAY '00:00:02';
GO 2
