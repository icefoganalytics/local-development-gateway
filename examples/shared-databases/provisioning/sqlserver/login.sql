-- Variables are supplied only after the provisioning service validates CHECKOUT_NAME.
IF SUSER_ID(N'$(database)') IS NULL
    CREATE LOGIN [$(database)] WITH PASSWORD = '$(password)', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
GO
-- Never reset an existing password or accept server-role membership.
IF EXISTS (
    SELECT 1 FROM sys.server_role_members
    WHERE member_principal_id = SUSER_ID(N'$(database)')
)
    THROW 51000, 'Example login has unexpected server-role membership.', 1;
IF EXISTS (
    SELECT 1 FROM sys.server_permissions
    WHERE grantee_principal_id = SUSER_ID(N'$(database)')
      AND state IN ('G', 'W') AND permission_name <> N'CONNECT SQL'
)
    THROW 51001, 'Example login has unexpected server-level grants.', 1;
DENY VIEW ANY DATABASE TO [$(database)];
GO
