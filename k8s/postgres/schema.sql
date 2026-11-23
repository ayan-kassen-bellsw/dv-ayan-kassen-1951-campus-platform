-- Reconcile via the container's postgres OS identity and local peer authentication.
SELECT pg_advisory_lock(1951, 1);
SELECT 'CREATE DATABASE campus' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'campus') \gexec
\connect campus
BEGIN;
SELECT pg_advisory_xact_lock(1951, 1);
SET LOCAL password_encryption = 'scram-sha-256';
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
\getenv root_pw PG_ROOT_SECRET
\getenv admin_pw PG_ADMIN_SECRET
\getenv rw_pw PG_RW_SECRET
\getenv ro_pw PG_RO_SECRET
SELECT format('CREATE ROLE %I LOGIN', name)
FROM (VALUES ('admin'), ('app_rw'), ('app_ro')) AS wanted(name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = wanted.name) \gexec
ALTER ROLE postgres PASSWORD :'root_pw';
ALTER ROLE admin LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'admin_pw';
ALTER ROLE app_rw LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 50 PASSWORD :'rw_pw';
ALTER ROLE app_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 10 PASSWORD :'ro_pw';

REVOKE ALL ON DATABASE campus FROM PUBLIC, app_rw, app_ro;
GRANT CONNECT ON DATABASE campus TO admin, app_rw, app_ro;
REVOKE ALL ON SCHEMA public FROM PUBLIC, app_rw, app_ro;
GRANT USAGE, CREATE ON SCHEMA public TO admin;
GRANT USAGE ON SCHEMA public TO app_rw, app_ro;
SET LOCAL ROLE admin;
CREATE TABLE IF NOT EXISTS public.items (
    id serial PRIMARY KEY,
    title varchar(200) NOT NULL,
    description text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    attachment_key varchar(300),
    attachment_name varchar(200),
    attachment_type varchar(100)
);
RESET ROLE;
ALTER TABLE public.items OWNER TO admin;
SET LOCAL ROLE admin;
CREATE TABLE IF NOT EXISTS public.attachment_blobs (
    item_id integer PRIMARY KEY REFERENCES public.items(id) ON DELETE CASCADE,
    content bytea NOT NULL
);
RESET ROLE;
ALTER TABLE public.attachment_blobs OWNER TO admin;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, app_rw, app_ro;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, app_rw, app_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE admin IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE admin IN SCHEMA public GRANT USAGE ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE admin IN SCHEMA public GRANT SELECT ON TABLES TO app_ro;
COMMIT;
