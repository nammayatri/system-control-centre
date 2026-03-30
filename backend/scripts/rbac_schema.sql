-- System Control Centre — RBAC Schema (Simplified)
-- Products and permissions are derived from Haskell ADTs, NOT stored in DB.
-- Only user/role/access/override data is stored here.

CREATE TABLE IF NOT EXISTS sc_person (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL UNIQUE,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    is_superadmin BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sc_role (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_slug TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    is_system_role BOOLEAN NOT NULL DEFAULT false,
    permissions TEXT[] DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_slug, name)
);

CREATE TABLE IF NOT EXISTS sc_person_product_access (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
    product_slug TEXT NOT NULL,
    role_id UUID NOT NULL REFERENCES sc_role(id),
    granted_by UUID REFERENCES sc_person(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (person_id, product_slug)
);

CREATE TABLE IF NOT EXISTS sc_person_permission_override (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
    product_slug TEXT NOT NULL,
    permission_action TEXT NOT NULL,
    override_type TEXT NOT NULL CHECK (override_type IN ('GRANT', 'DENY')),
    granted_by UUID REFERENCES sc_person(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (person_id, product_slug, permission_action)
);

CREATE TABLE IF NOT EXISTS sc_registration_token (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
    token TEXT NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS sc_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID REFERENCES sc_person(id),
    action TEXT NOT NULL,
    entity_type TEXT,
    entity_id TEXT,
    details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
