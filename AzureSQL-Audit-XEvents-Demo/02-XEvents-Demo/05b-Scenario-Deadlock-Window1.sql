/*==============================================================================
  XEvents DEMO - SCENARIO B : DEADLOCK  -  QUERY WINDOW 1 (of 2)
  File    : 05b-Scenario-Deadlock-Window1.sql
  Partner : 05c-Scenario-Deadlock-Window2.sql
  Session : demo_xe_errors_deadlocks  (must be RUNNING)

  SETUP  Open this file and 05c in two SSMS tabs, same database.
         Right-click a tab > "New Vertical Tab Group" -> side by side.

  HOW    1. Press F5 here (Window 1).
         2. Within 5 seconds press F5 in Window 2.
         3. Wait ~10-15 s. One window finishes, the other gets error 1205.

  WHAT   Classic lock-order deadlock:
           Window 1: Accounts(1)  -> wait 10 s -> Orders(1)
           Window 2: Orders(1)    -> wait 10 s -> Accounts(1)
         Each transaction holds what the other one needs. The deadlock
         monitor picks a victim (cheapest to roll back) and kills it.
  SAY    "Optimized locking and RCSI are on by default in Azure SQL Database,
         so deadlocks are rarer - but two writers touching the same rows in
         opposite order still deadlock. XE gives us the full graph: both
         statements, both sessions, the victim and the resources."
  EXPECT One window: 'Msg 1205 ... was deadlocked ... chosen as the deadlock
         victim'. The other: completes, '1 row affected' twice.
         06-Read-XE-Data.sql section 3 -> one deadlock graph (XML, clickable).
         The 1205 error itself also appears in section 1/2 (error_reported).
==============================================================================*/
SET NOCOUNT OFF;
SET DEADLOCK_PRIORITY NORMAL;
GO

BEGIN TRANSACTION;

    -- Step 1: lock account 1
    UPDATE xedemo.Accounts
       SET Balance = Balance - 100
     WHERE AccountId = 1;

    -- Step 2: "do some work" - gives Window 2 time to lock order 1
    WAITFOR DELAY '00:00:10';

    -- Step 3: now we need order 1 -> held by Window 2 -> DEADLOCK
    UPDATE xedemo.Orders
       SET Status = 'PAID'
     WHERE OrderId = 1;

COMMIT TRANSACTION;
GO

-- Safety net: if this window was the victim the transaction is already rolled
-- back; if anything is left open, close it so it doesn't block later demos.
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
SELECT @@SPID AS window1_session_id, @@TRANCOUNT AS open_transactions;  -- EXPECT 0
GO
