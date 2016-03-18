/*MIGRATION_DESCRIPTION
--CREATE: animals-Animal
New object Animal will be created in schema animals
--CREATE: animals-Animal-latinName
New property latinName will be created for Animal in animals
--CREATE: animals-Mammal
New object Mammal will be created in schema animals
--CREATE: animals-Animal with animals-Mammal
Object Mammal from schema animals can be persisted as mixin in animals.Animal
--CREATE: animals-Mammal-numberOfTits
New property numberOfTits will be created for Mammal in animals
--CREATE: animals-Bird
New object Bird will be created in schema animals
--CREATE: animals-Animal with animals-Bird
Object Bird from schema animals can be persisted as mixin in animals.Animal
--CREATE: animals-Bird-wingspan
New property wingspan will be created for Bird in animals
--CREATE: animals-Reptile
New object Reptile will be created in schema animals
--CREATE: animals-Animal with animals-Reptile
Object Reptile from schema animals can be persisted as mixin in animals.Animal
--CREATE: animals-Reptile-isDinosaur
New property isDinosaur will be created for Reptile in animals
--CREATE: animals-Zoo
New object Zoo will be created in schema animals
--CREATE: animals-Zoo-ID
New property ID will be created for Zoo in animals
--CREATE: animals-Zoo-animal
New property animal will be created for Zoo in animals
--CREATE: animals-Mammal-latinName
New property latinName will be created for Mammal in animals
--CREATE: animals-Bird-latinName
New property latinName will be created for Bird in animals
--CREATE: animals-Reptile-latinName
New property latinName will be created for Reptile in animals
MIGRATION_DESCRIPTION*/

DO $$ BEGIN
	IF EXISTS(SELECT * FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '-NGS-' AND c.relname = 'database_setting') THEN	
		IF EXISTS(SELECT * FROM "-NGS-".Database_Setting WHERE Key ILIKE 'mode' AND NOT Value ILIKE 'unsafe') THEN
			RAISE EXCEPTION 'Database upgrade is forbidden. Change database mode to allow upgrade';
		END IF;
	END IF;
END $$ LANGUAGE plpgsql;

DO $$
DECLARE script VARCHAR;
BEGIN
	IF NOT EXISTS(SELECT * FROM pg_namespace WHERE nspname = '-NGS-') THEN
		CREATE SCHEMA "-NGS-";
		COMMENT ON SCHEMA "-NGS-" IS 'NGS generated';
	END IF;
	IF NOT EXISTS(SELECT * FROM pg_namespace WHERE nspname = 'public') THEN
		CREATE SCHEMA public;
		COMMENT ON SCHEMA public IS 'NGS generated';
	END IF;
	SELECT array_to_string(array_agg('DROP VIEW IF EXISTS ' || quote_ident(n.nspname) || '.' || quote_ident(cl.relname) || ' CASCADE;'), '')
	INTO script
	FROM pg_class cl
	INNER JOIN pg_namespace n ON cl.relnamespace = n.oid
	INNER JOIN pg_description d ON d.objoid = cl.oid
	WHERE cl.relkind = 'v' AND d.description LIKE 'NGS volatile%';
	IF length(script) > 0 THEN
		EXECUTE script;
	END IF;
END $$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS "-NGS-".Database_Migration
(
	Ordinal SERIAL PRIMARY KEY,
	Dsls TEXT,
	Implementations BYTEA,
	Version VARCHAR,
	Applied_At TIMESTAMPTZ DEFAULT (CURRENT_TIMESTAMP)
);

CREATE OR REPLACE FUNCTION "-NGS-".Load_Last_Migration()
RETURNS "-NGS-".Database_Migration AS
$$
SELECT m FROM "-NGS-".Database_Migration m
ORDER BY Ordinal DESC 
LIMIT 1
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Persist_Concepts(dsls TEXT, implementations BYTEA, version VARCHAR)
  RETURNS void AS
$$
BEGIN
	INSERT INTO "-NGS-".Database_Migration(Dsls, Implementations, Version) VALUES(dsls, implementations, version);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION "-NGS-".Split_Uri(s text) RETURNS TEXT[] AS
$$
DECLARE i int;
DECLARE pos int;
DECLARE len int;
DECLARE res TEXT[];
DECLARE cur TEXT;
DECLARE c CHAR(1);
BEGIN
	pos = 0;
	i = 1;
	cur = '';
	len = length(s);
	LOOP
		pos = pos + 1;
		EXIT WHEN pos > len;
		c = substr(s, pos, 1);
		IF c = '/' THEN
			res[i] = cur;
			i = i + 1;
			cur = '';
		ELSE
			IF c = '\' THEN
				pos = pos + 1;
				c = substr(s, pos, 1);
			END IF;		
			cur = cur || c;
		END IF;
	END LOOP;
	res[i] = cur;
	return res;
END
$$ LANGUAGE plpgsql SECURITY DEFINER IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Load_Type_Info(
	OUT type_schema character varying, 
	OUT type_name character varying, 
	OUT column_name character varying, 
	OUT column_schema character varying,
	OUT column_type character varying, 
	OUT column_index smallint, 
	OUT is_not_null boolean,
	OUT is_ngs_generated boolean)
  RETURNS SETOF record AS
$BODY$
SELECT 
	ns.nspname::varchar, 
	cl.relname::varchar, 
	atr.attname::varchar, 
	ns_ref.nspname::varchar,
	typ.typname::varchar, 
	(SELECT COUNT(*) + 1
	FROM pg_attribute atr_ord
	WHERE 
		atr.attrelid = atr_ord.attrelid
		AND atr_ord.attisdropped = false
		AND atr_ord.attnum > 0
		AND atr_ord.attnum < atr.attnum)::smallint, 
	atr.attnotnull,
	coalesce(d.description LIKE 'NGS generated%', false)
FROM 
	pg_attribute atr
	INNER JOIN pg_class cl ON atr.attrelid = cl.oid
	INNER JOIN pg_namespace ns ON cl.relnamespace = ns.oid
	INNER JOIN pg_type typ ON atr.atttypid = typ.oid
	INNER JOIN pg_namespace ns_ref ON typ.typnamespace = ns_ref.oid
	LEFT JOIN pg_description d ON d.objoid = cl.oid
								AND d.objsubid = atr.attnum
WHERE
	(cl.relkind = 'r' OR cl.relkind = 'v' OR cl.relkind = 'c')
	AND ns.nspname NOT LIKE 'pg_%'
	AND ns.nspname != 'information_schema'
	AND atr.attnum > 0
	AND atr.attisdropped = FALSE
ORDER BY 1, 2, 6
$BODY$
  LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Safe_Notify(target varchar, name varchar, operation varchar, uris varchar[]) RETURNS VOID AS
$$
DECLARE message VARCHAR;
DECLARE array_size INT;
BEGIN
	array_size = array_upper(uris, 1);
	message = name || ':' || operation || ':' || uris::TEXT;
	IF (array_size > 0 and length(message) < 8000) THEN 
		PERFORM pg_notify(target, message);
	ELSEIF (array_size > 1) THEN
		PERFORM "-NGS-".Safe_Notify(target, name, operation, (SELECT array_agg(u) FROM (SELECT unnest(uris) u LIMIT (array_size+1)/2) u));
		PERFORM "-NGS-".Safe_Notify(target, name, operation, (SELECT array_agg(u) FROM (SELECT unnest(uris) u OFFSET (array_size+1)/2) u));
	ELSEIF (array_size = 1) THEN
		RAISE EXCEPTION 'uri can''t be longer than 8000 characters';
	END IF;	
END
$$ LANGUAGE PLPGSQL SECURITY DEFINER;

CREATE OR REPLACE FUNCTION "-NGS-".cast_int(int[]) RETURNS TEXT AS
$$ SELECT $1::TEXT[]::TEXT $$ LANGUAGE SQL IMMUTABLE COST 1;
CREATE OR REPLACE FUNCTION "-NGS-".cast_bigint(bigint[]) RETURNS TEXT AS
$$ SELECT $1::TEXT[]::TEXT $$ LANGUAGE SQL IMMUTABLE COST 1;

DO $$ BEGIN
	-- unfortunately only superuser can create such casts
	IF EXISTS(SELECT * FROM pg_catalog.pg_user WHERE usename = CURRENT_USER AND usesuper) THEN
		IF NOT EXISTS (SELECT * FROM pg_catalog.pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid WHERE s.typname = '_int4' AND t.typname = 'text') THEN
			CREATE CAST (int[] AS text) WITH FUNCTION "-NGS-".cast_int(int[]) AS ASSIGNMENT;
		END IF;
		IF NOT EXISTS (SELECT * FROM pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid WHERE s.typname = '_int8' AND t.typname = 'text') THEN
			CREATE CAST (bigint[] AS text) WITH FUNCTION "-NGS-".cast_bigint(bigint[]) AS ASSIGNMENT;
		END IF;
	END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri2(text, text) RETURNS text AS 
$$
BEGIN
	RETURN replace(replace($1, '\','\\'), '/', '\/')||'/'||replace(replace($2, '\','\\'), '/', '\/');
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri3(text, text, text) RETURNS text AS 
$$
BEGIN
	RETURN replace(replace($1, '\','\\'), '/', '\/')||'/'||replace(replace($2, '\','\\'), '/', '\/')||'/'||replace(replace($3, '\','\\'), '/', '\/');
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri4(text, text, text, text) RETURNS text AS 
$$
BEGIN
	RETURN replace(replace($1, '\','\\'), '/', '\/')||'/'||replace(replace($2, '\','\\'), '/', '\/')||'/'||replace(replace($3, '\','\\'), '/', '\/')||'/'||replace(replace($4, '\','\\'), '/', '\/');
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri5(text, text, text, text, text) RETURNS text AS 
$$
BEGIN
	RETURN replace(replace($1, '\','\\'), '/', '\/')||'/'||replace(replace($2, '\','\\'), '/', '\/')||'/'||replace(replace($3, '\','\\'), '/', '\/')||'/'||replace(replace($4, '\','\\'), '/', '\/')||'/'||replace(replace($5, '\','\\'), '/', '\/');
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri(text[]) RETURNS text AS 
$$
BEGIN
	RETURN (SELECT array_to_string(array_agg(replace(replace(u, '\','\\'), '/', '\/')), '/') FROM unnest($1) u);
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE TABLE IF NOT EXISTS "-NGS-".Database_Setting
(
	Key VARCHAR PRIMARY KEY,
	Value TEXT NOT NULL
);

CREATE OR REPLACE FUNCTION "-NGS-".Create_Type_Cast(function VARCHAR, schema VARCHAR, from_name VARCHAR, to_name VARCHAR)
RETURNS void
AS
$$
DECLARE header VARCHAR;
DECLARE source VARCHAR;
DECLARE footer VARCHAR;
DECLARE col_name VARCHAR;
DECLARE type VARCHAR = '"' || schema || '"."' || to_name || '"';
BEGIN
	header = 'CREATE OR REPLACE FUNCTION ' || function || '
RETURNS ' || type || '
AS
$BODY$
SELECT ROW(';
	footer = ')::' || type || '
$BODY$ IMMUTABLE LANGUAGE sql;';
	source = '';
	FOR col_name IN 
		SELECT 
			CASE WHEN 
				EXISTS (SELECT * FROM "-NGS-".Load_Type_Info() f 
					WHERE f.type_schema = schema AND f.type_name = from_name AND f.column_name = t.column_name)
				OR EXISTS(SELECT * FROM pg_proc p JOIN pg_type t_in ON p.proargtypes[0] = t_in.oid 
					JOIN pg_namespace n_in ON t_in.typnamespace = n_in.oid JOIN pg_namespace n ON p.pronamespace = n.oid
					WHERE array_upper(p.proargtypes, 1) = 0 AND n.nspname = 'public' AND t_in.typname = from_name AND p.proname = t.column_name) THEN t.column_name
				ELSE null
			END
		FROM "-NGS-".Load_Type_Info() t
		WHERE 
			t.type_schema = schema 
			AND t.type_name = to_name
		ORDER BY t.column_index 
	LOOP
		IF col_name IS NULL THEN
			source = source || 'null, ';
		ELSE
			source = source || '$1."' || col_name || '", ';
		END IF;
	END LOOP;
	IF (LENGTH(source) > 0) THEN 
		source = SUBSTRING(source, 1, LENGTH(source) - 2);
	END IF;
	EXECUTE (header || source || footer);
END
$$ LANGUAGE plpgsql;;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_namespace WHERE nspname = 'animals') THEN
		CREATE SCHEMA "animals";
		COMMENT ON SCHEMA "animals" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = '-ngs_Animal_type-') THEN	
		CREATE TYPE "animals"."-ngs_Animal_type-" AS ();
		COMMENT ON TYPE "animals"."-ngs_Animal_type-" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = 'Animal') THEN	
		CREATE TYPE "animals"."Animal" AS ();
		COMMENT ON TYPE "animals"."Animal" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = '-ngs_Mammal_type-') THEN	
		CREATE TYPE "animals"."-ngs_Mammal_type-" AS ();
		COMMENT ON TYPE "animals"."-ngs_Mammal_type-" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = 'Mammal') THEN	
		CREATE TYPE "animals"."Mammal" AS ();
		COMMENT ON TYPE "animals"."Mammal" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = '-ngs_Bird_type-') THEN	
		CREATE TYPE "animals"."-ngs_Bird_type-" AS ();
		COMMENT ON TYPE "animals"."-ngs_Bird_type-" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = 'Bird') THEN	
		CREATE TYPE "animals"."Bird" AS ();
		COMMENT ON TYPE "animals"."Bird" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = '-ngs_Reptile_type-') THEN	
		CREATE TYPE "animals"."-ngs_Reptile_type-" AS ();
		COMMENT ON TYPE "animals"."-ngs_Reptile_type-" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = 'Reptile') THEN	
		CREATE TYPE "animals"."Reptile" AS ();
		COMMENT ON TYPE "animals"."Reptile" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'animals' AND t.typname = '-ngs_Zoo_type-') THEN	
		CREATE TYPE "animals"."-ngs_Zoo_type-" AS ();
		COMMENT ON TYPE "animals"."-ngs_Zoo_type-" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'animals' AND c.relname = 'Zoo') THEN	
		CREATE TABLE "animals"."Zoo" ();
		COMMENT ON TABLE "animals"."Zoo" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'animals' AND c.relname = 'Zoo_sequence') THEN
		CREATE SEQUENCE "animals"."Zoo_sequence";
		COMMENT ON SEQUENCE "animals"."Zoo_sequence" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "animals"."cast_Animal_to_type"("animals"."Animal") RETURNS "animals"."-ngs_Animal_type-" AS $$ SELECT $1::text::"animals"."-ngs_Animal_type-" $$ IMMUTABLE LANGUAGE sql COST 1;
CREATE OR REPLACE FUNCTION "animals"."cast_Animal_to_type"("animals"."-ngs_Animal_type-") RETURNS "animals"."Animal" AS $$ SELECT $1::text::"animals"."Animal" $$ IMMUTABLE LANGUAGE sql COST 1;
CREATE OR REPLACE FUNCTION cast_to_text("animals"."Animal") RETURNS text AS $$ SELECT $1::VARCHAR $$ IMMUTABLE LANGUAGE sql COST 1;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid JOIN pg_namespace n ON n.oid = s.typnamespace AND n.oid = t.typnamespace
					WHERE n.nspname = 'animals' AND s.typname = 'Animal' AND t.typname = '-ngs_Animal_type-') THEN
		CREATE CAST ("animals"."-ngs_Animal_type-" AS "animals"."Animal") WITH FUNCTION "animals"."cast_Animal_to_type"("animals"."-ngs_Animal_type-") AS IMPLICIT;
		CREATE CAST ("animals"."Animal" AS "animals"."-ngs_Animal_type-") WITH FUNCTION "animals"."cast_Animal_to_type"("animals"."Animal") AS IMPLICIT;
		CREATE CAST ("animals"."Animal" AS text) WITH FUNCTION cast_to_text("animals"."Animal") AS ASSIGNMENT;
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Animal_type-' AND column_name = 'latinName') THEN
		ALTER TYPE "animals"."-ngs_Animal_type-" ADD ATTRIBUTE "latinName" VARCHAR;
		COMMENT ON COLUMN "animals"."-ngs_Animal_type-"."latinName" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Animal' AND column_name = 'latinName') THEN
		ALTER TYPE "animals"."Animal" ADD ATTRIBUTE "latinName" VARCHAR;
		COMMENT ON COLUMN "animals"."Animal"."latinName" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Animal' AND column_name = 'animals.Mammal') THEN
		ALTER TYPE "animals"."Animal" ADD ATTRIBUTE "animals.Mammal" "animals"."Mammal";
		COMMENT ON COLUMN "animals"."Animal"."animals.Mammal" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Animal_type-' AND column_name = 'animals.Mammal') THEN
		ALTER TYPE "animals"."-ngs_Animal_type-" ADD ATTRIBUTE "animals.Mammal" "animals"."-ngs_Mammal_type-";
		COMMENT ON COLUMN "animals"."-ngs_Animal_type-"."animals.Mammal" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Mammal_type-' AND column_name = 'numberOfTits') THEN
		ALTER TYPE "animals"."-ngs_Mammal_type-" ADD ATTRIBUTE "numberOfTits" INT;
		COMMENT ON COLUMN "animals"."-ngs_Mammal_type-"."numberOfTits" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Mammal' AND column_name = 'numberOfTits') THEN
		ALTER TYPE "animals"."Mammal" ADD ATTRIBUTE "numberOfTits" INT;
		COMMENT ON COLUMN "animals"."Mammal"."numberOfTits" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Animal' AND column_name = 'animals.Bird') THEN
		ALTER TYPE "animals"."Animal" ADD ATTRIBUTE "animals.Bird" "animals"."Bird";
		COMMENT ON COLUMN "animals"."Animal"."animals.Bird" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Animal_type-' AND column_name = 'animals.Bird') THEN
		ALTER TYPE "animals"."-ngs_Animal_type-" ADD ATTRIBUTE "animals.Bird" "animals"."-ngs_Bird_type-";
		COMMENT ON COLUMN "animals"."-ngs_Animal_type-"."animals.Bird" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Bird_type-' AND column_name = 'wingspan') THEN
		ALTER TYPE "animals"."-ngs_Bird_type-" ADD ATTRIBUTE "wingspan" FLOAT8;
		COMMENT ON COLUMN "animals"."-ngs_Bird_type-"."wingspan" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Bird' AND column_name = 'wingspan') THEN
		ALTER TYPE "animals"."Bird" ADD ATTRIBUTE "wingspan" FLOAT8;
		COMMENT ON COLUMN "animals"."Bird"."wingspan" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Animal' AND column_name = 'animals.Reptile') THEN
		ALTER TYPE "animals"."Animal" ADD ATTRIBUTE "animals.Reptile" "animals"."Reptile";
		COMMENT ON COLUMN "animals"."Animal"."animals.Reptile" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Animal_type-' AND column_name = 'animals.Reptile') THEN
		ALTER TYPE "animals"."-ngs_Animal_type-" ADD ATTRIBUTE "animals.Reptile" "animals"."-ngs_Reptile_type-";
		COMMENT ON COLUMN "animals"."-ngs_Animal_type-"."animals.Reptile" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Reptile_type-' AND column_name = 'isDinosaur') THEN
		ALTER TYPE "animals"."-ngs_Reptile_type-" ADD ATTRIBUTE "isDinosaur" BOOL;
		COMMENT ON COLUMN "animals"."-ngs_Reptile_type-"."isDinosaur" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Reptile' AND column_name = 'isDinosaur') THEN
		ALTER TYPE "animals"."Reptile" ADD ATTRIBUTE "isDinosaur" BOOL;
		COMMENT ON COLUMN "animals"."Reptile"."isDinosaur" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Zoo_type-' AND column_name = 'ID') THEN
		ALTER TYPE "animals"."-ngs_Zoo_type-" ADD ATTRIBUTE "ID" INT;
		COMMENT ON COLUMN "animals"."-ngs_Zoo_type-"."ID" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Zoo' AND column_name = 'ID') THEN
		ALTER TABLE "animals"."Zoo" ADD COLUMN "ID" INT;
		COMMENT ON COLUMN "animals"."Zoo"."ID" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Zoo_type-' AND column_name = 'animal') THEN
		ALTER TYPE "animals"."-ngs_Zoo_type-" ADD ATTRIBUTE "animal" "animals"."-ngs_Animal_type-";
		COMMENT ON COLUMN "animals"."-ngs_Zoo_type-"."animal" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Zoo' AND column_name = 'animal') THEN
		ALTER TABLE "animals"."Zoo" ADD COLUMN "animal" "animals"."Animal";
		COMMENT ON COLUMN "animals"."Zoo"."animal" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Mammal_type-' AND column_name = 'latinName') THEN
		ALTER TYPE "animals"."-ngs_Mammal_type-" ADD ATTRIBUTE "latinName" VARCHAR;
		COMMENT ON COLUMN "animals"."-ngs_Mammal_type-"."latinName" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Mammal' AND column_name = 'latinName') THEN
		ALTER TYPE "animals"."Mammal" ADD ATTRIBUTE "latinName" VARCHAR;
		COMMENT ON COLUMN "animals"."Mammal"."latinName" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Bird_type-' AND column_name = 'latinName') THEN
		ALTER TYPE "animals"."-ngs_Bird_type-" ADD ATTRIBUTE "latinName" VARCHAR;
		COMMENT ON COLUMN "animals"."-ngs_Bird_type-"."latinName" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Bird' AND column_name = 'latinName') THEN
		ALTER TYPE "animals"."Bird" ADD ATTRIBUTE "latinName" VARCHAR;
		COMMENT ON COLUMN "animals"."Bird"."latinName" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = '-ngs_Reptile_type-' AND column_name = 'latinName') THEN
		ALTER TYPE "animals"."-ngs_Reptile_type-" ADD ATTRIBUTE "latinName" VARCHAR;
		COMMENT ON COLUMN "animals"."-ngs_Reptile_type-"."latinName" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'animals' AND type_name = 'Reptile' AND column_name = 'latinName') THEN
		ALTER TYPE "animals"."Reptile" ADD ATTRIBUTE "latinName" VARCHAR;
		COMMENT ON COLUMN "animals"."Reptile"."latinName" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "animals"."cast_Mammal_to_type"("animals"."Mammal") RETURNS "animals"."-ngs_Mammal_type-" AS $$ SELECT $1::text::"animals"."-ngs_Mammal_type-" $$ IMMUTABLE LANGUAGE sql COST 1;
CREATE OR REPLACE FUNCTION "animals"."cast_Mammal_to_type"("animals"."-ngs_Mammal_type-") RETURNS "animals"."Mammal" AS $$ SELECT $1::text::"animals"."Mammal" $$ IMMUTABLE LANGUAGE sql COST 1;
CREATE OR REPLACE FUNCTION cast_to_text("animals"."Mammal") RETURNS text AS $$ SELECT $1::VARCHAR $$ IMMUTABLE LANGUAGE sql COST 1;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid JOIN pg_namespace n ON n.oid = s.typnamespace AND n.oid = t.typnamespace
					WHERE n.nspname = 'animals' AND s.typname = 'Mammal' AND t.typname = '-ngs_Mammal_type-') THEN
		CREATE CAST ("animals"."-ngs_Mammal_type-" AS "animals"."Mammal") WITH FUNCTION "animals"."cast_Mammal_to_type"("animals"."-ngs_Mammal_type-") AS IMPLICIT;
		CREATE CAST ("animals"."Mammal" AS "animals"."-ngs_Mammal_type-") WITH FUNCTION "animals"."cast_Mammal_to_type"("animals"."Mammal") AS IMPLICIT;
		CREATE CAST ("animals"."Mammal" AS text) WITH FUNCTION cast_to_text("animals"."Mammal") AS ASSIGNMENT;
	END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "animals"."cast_Bird_to_type"("animals"."Bird") RETURNS "animals"."-ngs_Bird_type-" AS $$ SELECT $1::text::"animals"."-ngs_Bird_type-" $$ IMMUTABLE LANGUAGE sql COST 1;
CREATE OR REPLACE FUNCTION "animals"."cast_Bird_to_type"("animals"."-ngs_Bird_type-") RETURNS "animals"."Bird" AS $$ SELECT $1::text::"animals"."Bird" $$ IMMUTABLE LANGUAGE sql COST 1;
CREATE OR REPLACE FUNCTION cast_to_text("animals"."Bird") RETURNS text AS $$ SELECT $1::VARCHAR $$ IMMUTABLE LANGUAGE sql COST 1;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid JOIN pg_namespace n ON n.oid = s.typnamespace AND n.oid = t.typnamespace
					WHERE n.nspname = 'animals' AND s.typname = 'Bird' AND t.typname = '-ngs_Bird_type-') THEN
		CREATE CAST ("animals"."-ngs_Bird_type-" AS "animals"."Bird") WITH FUNCTION "animals"."cast_Bird_to_type"("animals"."-ngs_Bird_type-") AS IMPLICIT;
		CREATE CAST ("animals"."Bird" AS "animals"."-ngs_Bird_type-") WITH FUNCTION "animals"."cast_Bird_to_type"("animals"."Bird") AS IMPLICIT;
		CREATE CAST ("animals"."Bird" AS text) WITH FUNCTION cast_to_text("animals"."Bird") AS ASSIGNMENT;
	END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "animals"."cast_Reptile_to_type"("animals"."Reptile") RETURNS "animals"."-ngs_Reptile_type-" AS $$ SELECT $1::text::"animals"."-ngs_Reptile_type-" $$ IMMUTABLE LANGUAGE sql COST 1;
CREATE OR REPLACE FUNCTION "animals"."cast_Reptile_to_type"("animals"."-ngs_Reptile_type-") RETURNS "animals"."Reptile" AS $$ SELECT $1::text::"animals"."Reptile" $$ IMMUTABLE LANGUAGE sql COST 1;
CREATE OR REPLACE FUNCTION cast_to_text("animals"."Reptile") RETURNS text AS $$ SELECT $1::VARCHAR $$ IMMUTABLE LANGUAGE sql COST 1;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid JOIN pg_namespace n ON n.oid = s.typnamespace AND n.oid = t.typnamespace
					WHERE n.nspname = 'animals' AND s.typname = 'Reptile' AND t.typname = '-ngs_Reptile_type-') THEN
		CREATE CAST ("animals"."-ngs_Reptile_type-" AS "animals"."Reptile") WITH FUNCTION "animals"."cast_Reptile_to_type"("animals"."-ngs_Reptile_type-") AS IMPLICIT;
		CREATE CAST ("animals"."Reptile" AS "animals"."-ngs_Reptile_type-") WITH FUNCTION "animals"."cast_Reptile_to_type"("animals"."Reptile") AS IMPLICIT;
		CREATE CAST ("animals"."Reptile" AS text) WITH FUNCTION cast_to_text("animals"."Reptile") AS ASSIGNMENT;
	END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW "animals"."Zoo_entity" AS
SELECT _entity."ID", _entity."animal"
FROM
	"animals"."Zoo" _entity
	;
COMMENT ON VIEW "animals"."Zoo_entity" IS 'NGS volatile';

CREATE OR REPLACE FUNCTION "URI"("animals"."Zoo_entity") RETURNS TEXT AS $$
SELECT CAST($1."ID" as TEXT)
$$ LANGUAGE SQL IMMUTABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION "animals"."cast_Zoo_to_type"("animals"."-ngs_Zoo_type-") RETURNS "animals"."Zoo_entity" AS $$ SELECT $1::text::"animals"."Zoo_entity" $$ IMMUTABLE LANGUAGE sql;
CREATE OR REPLACE FUNCTION "animals"."cast_Zoo_to_type"("animals"."Zoo_entity") RETURNS "animals"."-ngs_Zoo_type-" AS $$ SELECT $1::text::"animals"."-ngs_Zoo_type-" $$ IMMUTABLE LANGUAGE sql;

DO $$ BEGIN
	IF NOT EXISTS(SELECT * FROM pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid JOIN pg_namespace n ON n.oid = s.typnamespace AND n.oid = t.typnamespace
					WHERE n.nspname = 'animals' AND s.typname = 'Zoo_entity' AND t.typname = '-ngs_Zoo_type-') THEN
		CREATE CAST ("animals"."-ngs_Zoo_type-" AS "animals"."Zoo_entity") WITH FUNCTION "animals"."cast_Zoo_to_type"("animals"."-ngs_Zoo_type-") AS IMPLICIT;
		CREATE CAST ("animals"."Zoo_entity" AS "animals"."-ngs_Zoo_type-") WITH FUNCTION "animals"."cast_Zoo_to_type"("animals"."Zoo_entity") AS IMPLICIT;
	END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW "animals"."Zoo_unprocessed_events" AS
SELECT _aggregate."ID"
FROM
	"animals"."Zoo_entity" _aggregate
;
COMMENT ON VIEW "animals"."Zoo_unprocessed_events" IS 'NGS volatile';

CREATE OR REPLACE FUNCTION "animals"."insert_Zoo"(IN _inserted "animals"."Zoo_entity"[]) RETURNS VOID AS
$$
BEGIN
	INSERT INTO "animals"."Zoo" ("ID", "animal") VALUES(_inserted[1]."ID", _inserted[1]."animal");
	
	PERFORM pg_notify('aggregate_roots', 'animals.Zoo:Insert:' || array["URI"(_inserted[1])]::TEXT);
END
$$
LANGUAGE plpgsql SECURITY DEFINER;;

CREATE OR REPLACE FUNCTION "animals"."persist_Zoo"(
IN _inserted "animals"."Zoo_entity"[], IN _updated_original "animals"."Zoo_entity"[], IN _updated_new "animals"."Zoo_entity"[], IN _deleted "animals"."Zoo_entity"[]) 
	RETURNS VARCHAR AS
$$
DECLARE cnt int;
DECLARE uri VARCHAR;
DECLARE tmp record;
DECLARE _update_count int = array_upper(_updated_original, 1);
DECLARE _delete_count int = array_upper(_deleted, 1);

BEGIN

	SET CONSTRAINTS ALL DEFERRED;

	

	INSERT INTO "animals"."Zoo" ("ID", "animal")
	SELECT _i."ID", _i."animal" 
	FROM unnest(_inserted) _i;

	

	UPDATE "animals"."Zoo" as _tbl SET "ID" = (_u.changed)."ID", "animal" = (_u.changed)."animal"
	FROM (SELECT unnest(_updated_original) as original, unnest(_updated_new) as changed) _u
	WHERE _tbl."ID" = (_u.original)."ID";

	GET DIAGNOSTICS cnt = ROW_COUNT;
	IF cnt != _update_count THEN 
		RETURN 'Updated ' || cnt || ' row(s). Expected to update ' || _update_count || ' row(s).';
	END IF;

	

	DELETE FROM "animals"."Zoo"
	WHERE ("ID") IN (SELECT _d."ID" FROM unnest(_deleted) _d);

	GET DIAGNOSTICS cnt = ROW_COUNT;
	IF cnt != _delete_count THEN 
		RETURN 'Deleted ' || cnt || ' row(s). Expected to delete ' || _delete_count || ' row(s).';
	END IF;

	
	PERFORM "-NGS-".Safe_Notify('aggregate_roots', 'animals.Zoo', 'Insert', (SELECT array_agg(_i."URI") FROM unnest(_inserted) _i));
	PERFORM "-NGS-".Safe_Notify('aggregate_roots', 'animals.Zoo', 'Update', (SELECT array_agg(_u."URI") FROM unnest(_updated_original) _u));
	PERFORM "-NGS-".Safe_Notify('aggregate_roots', 'animals.Zoo', 'Change', (SELECT array_agg((_u.changed)."URI") FROM (SELECT unnest(_updated_original) as original, unnest(_updated_new) as changed) _u WHERE (_u.changed)."ID" != (_u.original)."ID"));
	PERFORM "-NGS-".Safe_Notify('aggregate_roots', 'animals.Zoo', 'Delete', (SELECT array_agg(_d."URI") FROM unnest(_deleted) _d));

	SET CONSTRAINTS ALL IMMEDIATE;

	RETURN NULL;
END
$$
LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION "animals"."update_Zoo"(IN _original "animals"."Zoo_entity"[], IN _updated "animals"."Zoo_entity"[]) RETURNS VARCHAR AS
$$
DECLARE cnt int;
BEGIN
	
	UPDATE "animals"."Zoo" AS _tab SET "ID" = _updated[1]."ID", "animal" = _updated[1]."animal" WHERE _tab."ID" = _original[1]."ID";
	GET DIAGNOSTICS cnt = ROW_COUNT;
	
	PERFORM pg_notify('aggregate_roots', 'animals.Zoo:Update:' || array["URI"(_original[1])]::TEXT);
	IF (_original[1]."ID" != _updated[1]."ID") THEN
		PERFORM pg_notify('aggregate_roots', 'animals.Zoo:Change:' || array["URI"(_updated[1])]::TEXT);
	END IF;
	RETURN CASE WHEN cnt = 0 THEN 'No rows updated' ELSE NULL END;
END
$$
LANGUAGE plpgsql SECURITY DEFINER;;

SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Animal_to_type"("animals"."-ngs_Animal_type-")', 'animals', '-ngs_Animal_type-', 'Animal');
SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Animal_to_type"("animals"."Animal")', 'animals', 'Animal', '-ngs_Animal_type-');

SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Mammal_to_type"("animals"."-ngs_Mammal_type-")', 'animals', '-ngs_Mammal_type-', 'Mammal');
SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Mammal_to_type"("animals"."Mammal")', 'animals', 'Mammal', '-ngs_Mammal_type-');

SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Bird_to_type"("animals"."-ngs_Bird_type-")', 'animals', '-ngs_Bird_type-', 'Bird');
SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Bird_to_type"("animals"."Bird")', 'animals', 'Bird', '-ngs_Bird_type-');

SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Reptile_to_type"("animals"."-ngs_Reptile_type-")', 'animals', '-ngs_Reptile_type-', 'Reptile');
SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Reptile_to_type"("animals"."Reptile")', 'animals', 'Reptile', '-ngs_Reptile_type-');

SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Zoo_to_type"("animals"."-ngs_Zoo_type-")', 'animals', '-ngs_Zoo_type-', 'Zoo_entity');
SELECT "-NGS-".Create_Type_Cast('"animals"."cast_Zoo_to_type"("animals"."Zoo_entity")', 'animals', 'Zoo_entity', '-ngs_Zoo_type-');
UPDATE "animals"."Zoo" SET "ID" = 0 WHERE "ID" IS NULL;
UPDATE "animals"."Zoo" SET "animal" = ROW(NULL,NULL,NULL,NULL) WHERE "animal"::TEXT IS NULL;

DO $$ 
DECLARE _pk VARCHAR;
BEGIN
	IF EXISTS(SELECT * FROM pg_index i JOIN pg_class c ON i.indrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE i.indisprimary AND n.nspname = 'animals' AND c.relname = 'Zoo') THEN
		SELECT array_to_string(array_agg(sq.attname), ', ') INTO _pk
		FROM
		(
			SELECT atr.attname
			FROM pg_index i
			JOIN pg_class c ON i.indrelid = c.oid 
			JOIN pg_attribute atr ON atr.attrelid = c.oid 
			WHERE 
				c.oid = '"animals"."Zoo"'::regclass
				AND atr.attnum = any(i.indkey)
				AND indisprimary
			ORDER BY (SELECT i FROM generate_subscripts(i.indkey,1) g(i) WHERE i.indkey[i] = atr.attnum LIMIT 1)
		) sq;
		IF ('ID' != _pk) THEN
			RAISE EXCEPTION 'Different primary key defined for table animals.Zoo. Expected primary key: ID. Found: %', _pk;
		END IF;
	ELSE
		ALTER TABLE "animals"."Zoo" ADD CONSTRAINT "pk_Zoo" PRIMARY KEY("ID");
		COMMENT ON CONSTRAINT "pk_Zoo" ON "animals"."Zoo" IS 'NGS generated';
	END IF;
END $$ LANGUAGE plpgsql;
ALTER TABLE "animals"."Zoo" ALTER "ID" SET NOT NULL;

DO $$ 
BEGIN
	IF NOT EXISTS(SELECT * FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'animals' AND c.relname = 'Zoo_ID_seq' AND c.relkind = 'S') THEN
		CREATE SEQUENCE "animals"."Zoo_ID_seq";
		ALTER TABLE "animals"."Zoo"	ALTER COLUMN "ID" SET DEFAULT NEXTVAL('"animals"."Zoo_ID_seq"');
		PERFORM SETVAL('"animals"."Zoo_ID_seq"', COALESCE(MAX("ID"), 0) + 1000) FROM "animals"."Zoo";
	END IF;
END $$ LANGUAGE plpgsql;
ALTER TABLE "animals"."Zoo" ALTER "animal" SET NOT NULL;

SELECT "-NGS-".Persist_Concepts('"d:\\Code\\mixin-example\\.\\dsl\\comments.dsl"=>"module animals
{
  mixin Animal {
    String latinName;
  }

  value Mammal {
    has mixin Animal;
    Int numberOfTits;
  }

  value Bird {
    has mixin Animal;
    Double wingspan;
  }

  value Reptile {
    has mixin Animal;
    Boolean isDinosaur;
  }

  aggregate Zoo {
    Animal animal;
  }
}
"', '\x','1.5.5920.20224');