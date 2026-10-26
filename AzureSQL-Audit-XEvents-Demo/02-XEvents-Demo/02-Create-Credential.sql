/*==============================================================================
  XEvents DEMO - STEP 1 : DATABASE SCOPED CREDENTIAL FOR THE BLOB CONTAINER
  File : 02-Create-Credential.sql
  Run  : in the USER database (e.g. sqldb-auditdemo) - NOT in master.
  Needs: CONTROL on the database (db_owner / server admin / Entra admin).

  BEFORE YOU RUN
    Create the private xevents container and assign the server identity's
    Storage Blob Data Contributor role manually in the portal (README step 2).
    Ctrl+H -> replace <ContainerUrl> with the confirmed container URL:
        https://<storage-account>.blob.core.windows.net/xevents
    * no trailing slash
    * same casing as you will use in 03-Create-XE-Sessions.sql

  WHAT  The event_file target in Azure SQL Database always writes to Azure Blob
        Storage. The engine finds "how to authenticate" by looking for a
        database scoped credential whose NAME equals the container URL.
  SAY   "No secret anywhere: the logical server's managed identity has
        Storage Blob Data Contributor on the storage account, and this
        credential just says: use that identity for this container."
  EXPECT One row in the verification query with
        credential_identity = 'MANAGED IDENTITY'.
==============================================================================*/
SET NOCOUNT ON;
GO

-- Safety check: are we in a user database?
SELECT DB_NAME() AS current_database,
       CASE WHEN DB_NAME() = N'master'
            THEN 'WRONG DATABASE - switch to your user database!'
            ELSE 'OK' END AS check_result;
GO

/*------------------------------------------------------------------------------
  1a. Managed Identity credential (no secret or database master key required).
      Name MUST equal the container URL, without trailing slash.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials
           WHERE name = N'<ContainerUrl>')
    DROP DATABASE SCOPED CREDENTIAL [<ContainerUrl>];
GO

CREATE DATABASE SCOPED CREDENTIAL [<ContainerUrl>]
WITH IDENTITY = 'MANAGED IDENTITY';
GO

/*------------------------------------------------------------------------------
  1b. VERIFY
  EXPECT: 1 row, name = your container URL (no trailing '/'),
          credential_identity = MANAGED IDENTITY.
------------------------------------------------------------------------------*/
SELECT  name                AS credential_name,
        credential_identity,
        create_date,
        CASE WHEN RIGHT(name, 1) = N'/'
             THEN 'PROBLEM: trailing slash - recreate without it'
             WHEN name NOT LIKE N'https://%.blob.core.windows.net/%'
             THEN 'CHECK: name does not look like a blob container URL'
             ELSE 'OK' END   AS sanity_check
FROM    sys.database_scoped_credentials
WHERE   name LIKE N'https://%.blob.core.windows.net/%'
ORDER BY create_date DESC;
GO
