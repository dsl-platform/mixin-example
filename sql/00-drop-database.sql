-- Terminate all database connections
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'animals_db';

-- Drop database
DROP DATABASE "animals_db";

-- Drop owner
DROP ROLE "animals_user";
