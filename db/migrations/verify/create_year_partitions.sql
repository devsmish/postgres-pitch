-- Verify pitch:create_year_partitions on pg

-- The function exists with its two arguments and returns INTEGER, and PUBLIC
-- has no EXECUTE on it (a NULL proacl would mean the default: PUBLIC may run it).
DO $$
BEGIN
    ASSERT (
        SELECT count(*)
        FROM pg_proc
        WHERE
            oid = to_regprocedure('public.create_year_partitions(integer,integer)')
            AND prorettype = 'integer'::regtype
            AND proacl IS NOT NULL
    ) = 1, 'create_year_partitions(integer, integer) should exist and have an explicit ACL';

    ASSERT NOT EXISTS (
        SELECT 1
        FROM pg_proc AS p
        CROSS JOIN LATERAL aclexplode(p.proacl) AS a
        WHERE
            p.oid = to_regprocedure('public.create_year_partitions(integer,integer)')
            AND a.grantee = 0
    ), 'PUBLIC should not have EXECUTE on create_year_partitions';
END
$$;
