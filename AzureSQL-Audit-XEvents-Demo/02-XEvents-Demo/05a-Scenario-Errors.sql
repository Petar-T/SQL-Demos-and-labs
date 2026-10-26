/*==============================================================================
  XEvents DEMO - SCENARIO A : ERRORS & ATTENTIONS
  File    : 05a-Scenario-Errors.sql
  Session : demo_xe_errors_deadlocks  (must be RUNNING)

  WHAT   Fire five typical application errors plus one client cancel.
         Each block is its own batch (GO), so one failure does not stop the
         next. Run the whole file with F5 - the red messages are expected!
  SAY    "Every one of these is something a user would report as 'the app
         failed'. Without XE you only have the app log - if it logged at all.
         With XE you get the error number, the statement, the app, host and
         login, server side."
  EXPECT Messages tab: 8134, 208, 245, 2627, 50000 (all severity >= 11).
         Then 06-Read-XE-Data.sql section 1 / 2 shows the same errors with
         sql_text, client_app_name, client_hostname and username.
==============================================================================*/

-- A1. Divide by zero                         -> error 8134, severity 16
SELECT 1 / 0 AS boom;
GO

-- A2. Invalid object name (typo / missing deployment) -> error 208, severity 16
SELECT * FROM dbo.CustomerOrdersThatDoNotExist;
GO

-- A3. Conversion error (bad input data)      -> error 245, severity 16
SELECT CAST(N'ikke-et-tall' AS int) AS conversion_failure;
GO

-- A4. Primary key violation (duplicate)       -> error 2627, severity 14
INSERT INTO xedemo.Accounts (AccountId, Owner, Balance)
VALUES (1, N'Duplicate Nordmann', 1.00);
GO

-- A5. Application-raised error                -> error 50000, severity 16
RAISERROR (N'XE demo: payment service rejected order %d', 16, 1, 42);
GO

/*------------------------------------------------------------------------------
  A6. ATTENTION (client cancel / command timeout)
  WHAT   The client aborts a running request. In production this is usually
         an application command timeout (e.g. .NET default 30 s) - the server
         just sees an 'attention'. There is NO error message on the server.
  HOW    When F5 reaches this batch (or highlight it + F5), wait ~3 seconds,
         then press the red "Cancel Executing Query" button (Alt+Break).
  EXPECT "Query was canceled by user." in SSMS.
         One sqlserver.attention event in the ring buffer, with sql_text.
  SAY    "Timeouts are invisible in the server error log. XE's attention
         event is how you prove 'the app gave up after 30 seconds'."
------------------------------------------------------------------------------*/
WAITFOR DELAY '00:00:30';
SELECT N'If you can read this, you forgot to press Cancel :-)' AS hint;
/*------------------------------------------------------------------------------
  OPTIONAL A7. Real command timeout from a client tool (no button press):
    sqlcmd -S <server>.database.windows.net -d <database> -G -t 3 ^
           -Q "WAITFOR DELAY '00:00:10'"
  (-t 3 = 3 s query timeout -> client sends attention -> same event.)
------------------------------------------------------------------------------*/
