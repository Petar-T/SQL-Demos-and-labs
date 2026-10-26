/*==============================================================================
  XEvents DEMO - SCENARIO C : BLOCKING  -  QUERY WINDOW 2 = THE VICTIM
  File    : 05e-Scenario-Blocking-Window2.sql
  Partner : 05d-Scenario-Blocking-Window1.sql (run its STEP 1 first)

  WHAT   Azure SQL Database has READ COMMITTED SNAPSHOT (RCSI) on by default:
         a normal SELECT reads the last committed version and is NOT blocked
         by a writer. To show blocking we use the READCOMMITTEDLOCK hint -
         exactly what legacy apps, ORMs with lock hints, or REPEATABLE READ /
         SERIALIZABLE transactions do in real life.
  SAY    "First the good news: a plain SELECT is not blocked - that's RCSI.
         Now the same query the way some legacy code writes it..."
  EXPECT C1 returns immediately (old committed balance 25000.00).
         C2 hangs ("Executing query...") until Window 1 runs ROLLBACK.
==============================================================================*/

-- C1. Plain SELECT under RCSI -> NOT blocked (returns at once)
SELECT AccountId, Owner, Balance
FROM   xedemo.Accounts
WHERE  AccountId = 2;
GO

-- C2. Locking read -> BLOCKED until the blocker commits / rolls back
SELECT AccountId, Owner, Balance
FROM   xedemo.Accounts WITH (READCOMMITTEDLOCK)
WHERE  AccountId = 2;
/*------------------------------------------------------------------------------
  ALTERNATIVE C3 - writer vs writer (always blocks, no hint needed).
  Highlight + F5 instead of C2 if you prefer:

UPDATE xedemo.Accounts SET Balance = Balance - 1 WHERE AccountId = 2;

------------------------------------------------------------------------------*/
