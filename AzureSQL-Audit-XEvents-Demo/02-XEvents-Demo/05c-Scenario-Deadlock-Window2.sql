/*==============================================================================
  XEvents DEMO - SCENARIO B : DEADLOCK  -  QUERY WINDOW 2 (of 2)
  File    : 05c-Scenario-Deadlock-Window2.sql
  Partner : 05b-Scenario-Deadlock-Window1.sql

  HOW    Start Window 1 FIRST, then press F5 here within 5 seconds.

  WHAT   Same two rows as Window 1, opposite order:
           Orders(1) -> wait 10 s -> Accounts(1)
  EXPECT One of the two windows gets:
           Msg 1205, Level 13 - Transaction (Process ID nn) was deadlocked on
           lock resources with another process and has been chosen as the
           deadlock victim. Rerun the transaction.
  SAY    "1205 is a retryable error - apps should retry with a small random
         back-off. XE tells us WHY it happened so we can fix the access order
         or indexing instead of just retrying forever."
==============================================================================*/
SET NOCOUNT OFF;
SET DEADLOCK_PRIORITY NORMAL;
GO

BEGIN TRANSACTION;

    -- Step 1: lock order 1
    UPDATE xedemo.Orders
       SET Status = 'SHIPPED'
     WHERE OrderId = 1;

    -- Step 2: "do some work"
    WAITFOR DELAY '00:00:10';

    -- Step 3: now we need account 1 -> held by Window 1 -> DEADLOCK
    UPDATE xedemo.Accounts
       SET Balance = Balance + 100
     WHERE AccountId = 1;

COMMIT TRANSACTION;
GO

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
SELECT @@SPID AS window2_session_id, @@TRANCOUNT AS open_transactions;  -- EXPECT 0
/*------------------------------------------------------------------------------
  TIP  Want to choose the victim on stage? Before re-running, set in THIS
       window:  SET DEADLOCK_PRIORITY LOW;   -> Window 2 is always the victim.
------------------------------------------------------------------------------*/
