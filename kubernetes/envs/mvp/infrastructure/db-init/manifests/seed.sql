-- Seed script for Aegis AI
-- Initializes local developer environment.

INSERT INTO companies (id, name, logo_url, is_active)
VALUES ('00000000-0000-0000-0000-000000000001', 'Aegis AI', 'https://aegis-ai.com/logo.png', true)
ON CONFLICT (name) DO NOTHING;

INSERT INTO users (id, company_id, email, password_hash, role, is_active)
VALUES (
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    'admin@aegis-ai.com',
    '$2a$10$wE70pU2M2n1tS9.HlI1vIuXmB76I7W06S3WfH6G8xO1ev4k5aZ6', -- Default: admin_password_123
    'superadmin',
    true
)
ON CONFLICT (email) DO NOTHING;

UPDATE companies
SET owner_id = '00000000-0000-0000-0000-000000000002'
WHERE id = '00000000-0000-0000-0000-000000000001'
  AND (owner_id IS NULL OR owner_id != '00000000-0000-0000-0000-000000000002');
