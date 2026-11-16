IF DB_ID(N'$(database)') IS NULL
    CREATE DATABASE [$(database)];
GO
ALTER AUTHORIZATION ON DATABASE::[$(database)] TO sa;
ALTER DATABASE [$(database)] SET TRUSTWORTHY OFF;
ALTER DATABASE [$(database)] SET DB_CHAINING OFF;
GO
USE [$(database)];
REVOKE CONNECT FROM guest;
IF USER_ID(N'$(database)') IS NULL
    CREATE USER [$(database)] FOR LOGIN [$(database)];
ALTER ROLE db_owner ADD MEMBER [$(database)];
GRANT CONNECT TO [$(database)];
GO
-- Explicit denials defend against accidental PUBLIC grants; guest is disabled.
DECLARE @other sysname, @sql nvarchar(max);
DECLARE other_logins CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM master.sys.server_principals
    WHERE name IN (N'alpha_development', N'alpha_test', N'beta_development', N'beta_test')
      AND name <> N'$(database)';
OPEN other_logins;
FETCH NEXT FROM other_logins INTO @other;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'';
    IF USER_ID(@other) IS NULL
        SET @sql = N'CREATE USER ' + QUOTENAME(@other) + N' FOR LOGIN ' + QUOTENAME(@other) + N'; ';
    SET @sql += N'DENY CONNECT TO ' + QUOTENAME(@other) + N';';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM other_logins INTO @other;
END;
CLOSE other_logins;
DEALLOCATE other_logins;
GO
