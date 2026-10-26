/*==============================================================================
  XEvents DEMO - SETUP : DEMO SCHEMA, TABLES AND A SLOW-QUERY HELPER
  File : 04-Setup-Demo-Objects.sql
  Run  : once, in the USER database, before the scenarios (re-runnable).

  WHAT   Schema [xedemo] with two tiny tables used by the deadlock and
         blocking scenarios, plus xedemo.usp_SlowReport - a deliberately
         CPU-heavy query used by the slow-query scenario.
  SAY    (nothing - run this before the audience arrives)
  EXPECT 5 accounts, 10 orders, isolation/locking check row at the end.
==============================================================================*/
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'xedemo') IS NULL
    EXEC (N'CREATE SCHEMA xedemo AUTHORIZATION dbo;');
GO

DROP TABLE IF EXISTS xedemo.Orders;
DROP TABLE IF EXISTS xedemo.Accounts;
GO

CREATE TABLE xedemo.Accounts
(
    AccountId  int            NOT NULL CONSTRAINT PK_xedemo_Accounts PRIMARY KEY,
    Owner      nvarchar(50)   NOT NULL,
    Balance    decimal(12,2)  NOT NULL
);

-- No foreign key on purpose: keeps the lock picture simple for the demo.
CREATE TABLE xedemo.Orders
(
    OrderId    int            NOT NULL CONSTRAINT PK_xedemo_Orders PRIMARY KEY,
    AccountId  int            NOT NULL,
    Amount     decimal(12,2)  NOT NULL,
    Status     varchar(20)    NOT NULL
);
GO

INSERT INTO xedemo.Accounts (AccountId, Owner, Balance) VALUES
    (1, N'Ola Nordmann',    10000.00),
    (2, N'Kari Nordmann',   25000.00),
    (3, N'Per Hansen',       5000.00),
    (4, N'Ingrid Johansen', 12500.00),
    (5, N'Lars Olsen',        750.00);

INSERT INTO xedemo.Orders (OrderId, AccountId, Amount, Status) VALUES
    ( 1, 1,  100.00, 'NEW'),
    ( 2, 1,  250.00, 'NEW'),
    ( 3, 2,   75.50, 'PAID'),
    ( 4, 2, 1200.00, 'NEW'),
    ( 5, 3,   49.90, 'SHIPPED'),
    ( 6, 3,  300.00, 'NEW'),
    ( 7, 4,  999.00, 'PAID'),
    ( 8, 4,   15.00, 'NEW'),
    ( 9, 5,  500.00, 'NEW'),
    (10, 5,   20.00, 'CANCELLED');
GO

/*------------------------------------------------------------------------------
  Slow-query helper.
  A real CPU-bound query (cross join + aggregate) so cpu_time ~= duration.
  @Multiplier scales the work: ~2,000 rows in sys.all_objects ->
  2,000 x 2,000 x @Multiplier rows. Tune so one call takes 2-5 s on your SKU
  (start with 10; lower on vCore/Premium, raise if it finishes under 1 s).

  Contrast for the talk track: WAITFOR DELAY registers DURATION but almost
  no CPU - useful as a quick fallback and to explain duration vs cpu_time.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE xedemo.usp_SlowReport
    @Multiplier int = 10
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  COUNT_BIG(*)                                  AS row_combinations,
            SUM(CAST((a.object_id ^ b.object_id) % 97 AS bigint)) AS pseudo_checksum
    FROM    sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
    CROSS JOIN (SELECT TOP (@Multiplier) 1 AS n FROM sys.all_objects) AS m
    OPTION (MAXDOP 1);
END;
GO

/*------------------------------------------------------------------------------
  Verify
------------------------------------------------------------------------------*/
SELECT (SELECT COUNT(*) FROM xedemo.Accounts) AS accounts,   -- EXPECT 5
       (SELECT COUNT(*) FROM xedemo.Orders)   AS orders;     -- EXPECT 10

-- Talk-track context: Azure SQL Database defaults.
-- EXPECT is_read_committed_snapshot_on = 1 (readers don't block writers)
--        is_optimized_locking_on       = 1 (always on in Azure SQL Database)
SELECT  name,
        is_read_committed_snapshot_on,
        snapshot_isolation_state_desc,
        is_optimized_locking_on
FROM    sys.databases
WHERE   name = DB_NAME();

-- How many rows will the slow helper multiply?  (~2,000 is typical)
SELECT COUNT(*) AS all_objects_rows FROM sys.all_objects;
GO
