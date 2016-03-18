-- Create database owner
CREATE ROLE "animals_user" PASSWORD 'animals_pass' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT LOGIN;

-- Create database
CREATE DATABASE "animals_db" OWNER "animals_user" ENCODING 'utf8' TEMPLATE "template1";
