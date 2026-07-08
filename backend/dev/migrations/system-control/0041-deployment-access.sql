CREATE TABLE IF NOT EXISTS sc_person_deployment_access (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
    product_slug TEXT NOT NULL,
    app_group TEXT NOT NULL,
    role_id UUID NOT NULL REFERENCES sc_role(id),
    granted_by UUID REFERENCES sc_person(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (person_id, product_slug, app_group)
);

CREATE INDEX IF NOT EXISTS idx_deployment_access_person ON sc_person_deployment_access(person_id, product_slug);
CREATE INDEX IF NOT EXISTS idx_deployment_access_app_group ON sc_person_deployment_access(product_slug, app_group);

ANALYZE;
