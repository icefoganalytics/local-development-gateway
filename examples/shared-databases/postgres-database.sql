SELECT format('CREATE DATABASE %I OWNER %I', :'database', :'database')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'database')
\gexec
-- Existing data stays in place; unexpected ownership is an error, not a takeover.
SELECT 1 / CASE WHEN EXISTS (
  SELECT FROM pg_database JOIN pg_roles ON pg_roles.oid = datdba
  WHERE datname = :'database' AND rolname = :'database'
) THEN 1 ELSE 0 END AS expected_owner;
REVOKE CONNECT, TEMPORARY ON DATABASE :"database" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"database" TO :"database";
-- Remove any stale grants to the other disposable identities.
SELECT format('REVOKE ALL ON DATABASE %I FROM %I', :'database', rolname)
FROM pg_roles
WHERE rolname LIKE 'app\_%' ESCAPE '\'
  AND rolname <> :'database'
\gexec
