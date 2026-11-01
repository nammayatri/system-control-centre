-- 0060: pinned apps (Mobile Releases v2).
--
-- Each release manager pins the store listings they look after; the v2 home,
-- releases and apps views filter to them. Per person, per app_catalog row —
-- both sides cascade so deleting a person or an app never leaves stale pins.

CREATE TABLE IF NOT EXISTS mobile_app_pin (
  person_id      UUID        NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
  app_catalog_id INTEGER     NOT NULL REFERENCES app_catalog(id) ON DELETE CASCADE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (person_id, app_catalog_id)
);
