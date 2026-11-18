-- Never ALTER PASSWORD on an existing role.
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', :'role', :'password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')
\gexec
-- Fail rather than reuse an identity with elevated rights or inherited roles.
SELECT 1 / CASE WHEN EXISTS (
  SELECT FROM pg_roles
  WHERE rolname = :'role' AND rolcanlogin
    AND NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
    AND NOT EXISTS (SELECT FROM pg_auth_members WHERE member = pg_roles.oid)
) THEN 1 ELSE 0 END AS restricted_role;
