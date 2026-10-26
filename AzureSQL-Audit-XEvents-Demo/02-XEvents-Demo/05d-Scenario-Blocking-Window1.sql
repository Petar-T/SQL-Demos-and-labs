/*==============================================================================
  XEvents DEMO - SCENARIO C : BLOCKING  -  QUERY WINDOW 1 = THE BLOCKER
  File    : 05d-Scenario-Blocking-Window1.sql
  Partner : 05e-Scenario-Blocking-Window2.sql
  Session : demo_xe_blocking  (must be RUNNING)

  HOW    STEP 1  F5 here: opens a transaction and updates account 2 - and
                 deliberately does NOT commit ("the user went to lunch").
         -> now run Window 2 (05e). It will hang.
         STEP 1b (optional) highlight + run the live DMV query below while
                 Window 2 is waiting.
         STEP 2  After ~15 s: highlight the ROLLBACK line below + F5.
                 Window 2 completes immediately.

  WHAT   Writer holds a lock, a locking reader waits. sqlos.wait_completed
         fires when the WAIT ENDS (i.e. after STEP 2) with the wait type,
         the duration in ms and the waiting statement.
  SAY    "blocked_process_report isn't available in Azure SQL Database - you
         can't set the threshold. Long LCK_M_* or verified transaction-resource
         locking waits show the waiting side,
         and the Azure Monitor 'Blocks' category covers it at platform level."
  EXPECT STEP 1: '1 row affected', blocker_session_id, open_transactions = 1.
         After STEP 2: 06 section 2b shows a LCK_M_* wait or the observed
         optimized-locking XACT_WITH_RESOURCE_TO_READ (~16781 ms in rehearsal).
         XACT_WITH_RESOURCE_TO_MODIFY is also retained for writer waits.
==============================================================================*/

/*==== STEP 1 : the blocker =================================================*/
BEGIN TRANSACTION;

UPDATE xedemo.Accounts
   SET Balance = Balance + 1
 WHERE AccountId = 2;

SELECT @@SPID AS blocker_session_id, @@TRANCOUNT AS open_transactions;  -- EXPECT 1
-- no COMMIT on purpose
/*==== STEP 1b (optional) : the LIVE view, while Window 2 is waiting ==========
   Highlight from SELECT to the semicolon and press F5.
   EXPECT waiter session -> blocking_session_id = blocker; LCK_M_* or verified
          XACT_WITH_RESOURCE_TO_READ / XACT_WITH_RESOURCE_TO_MODIFY wait.

SELECT  r.session_id,
        r.blocking_session_id,
        r.wait_type,
        r.wait_time        AS wait_time_ms,
        r.wait_resource,
        t.text             AS waiting_sql
FROM    sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   r.blocking_session_id <> 0;

=============================================================================*/


/*==== STEP 2 : release the lock ==============================================
   Highlight ONLY the next line and press F5:

ROLLBACK TRANSACTION;

   EXPECT Window 2 returns its row immediately.
   Then verify nothing is left open (highlight + F5):

SELECT @@TRANCOUNT AS open_transactions;   -- EXPECT 0

=============================================================================*/
