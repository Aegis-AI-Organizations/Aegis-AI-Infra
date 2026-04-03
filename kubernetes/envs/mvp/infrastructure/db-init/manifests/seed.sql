-- Seed script for Aegis AI
-- Initializes local developer environment.

WITH upsert_company AS (
  INSERT INTO companies (name, logo_url, is_active)
  VALUES ('Aegis AI', 'https://aegis-ai.com/logo.png', true)
  ON CONFLICT (name) DO UPDATE SET
    logo_url = EXCLUDED.logo_url,
    is_active = EXCLUDED.is_active
  RETURNING id
), upsert_user AS (
  INSERT INTO users (company_id, name, email, password_hash, role, is_active)
  VALUES (
    (SELECT id FROM upsert_company),
    INITCAP(split_part(:'AEGIS_SEED_USER_EMAIL', '@', 1)),
    :'AEGIS_SEED_USER_EMAIL',
    crypt(:'AEGIS_SEED_USER_PASSWORD', gen_salt('bf', 10)),
    'superadmin',
    true
  )
  ON CONFLICT (email) DO UPDATE SET
    password_hash = CASE
      WHEN users.password_hash = crypt(:'AEGIS_SEED_USER_PASSWORD', users.password_hash)
        THEN users.password_hash
      ELSE crypt(:'AEGIS_SEED_USER_PASSWORD', gen_salt('bf', 10))
    END,
    name = EXCLUDED.name,
    role = EXCLUDED.role,
    is_active = EXCLUDED.is_active,
    company_id = EXCLUDED.company_id
  RETURNING id, company_id
)
UPDATE companies c
SET owner_id = u.id
FROM upsert_user u
WHERE c.id = u.company_id
  AND c.owner_id IS DISTINCT FROM u.id;
