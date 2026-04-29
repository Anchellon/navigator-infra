-- ============================================================
-- saved_services Table DDL
-- Stores services bookmarked by a user.
-- user_id is an opaque string (Auth0 sub) — no FK to a users table.
-- UNIQUE (user_id, service_id) prevents duplicate saves.
-- ============================================================

CREATE TABLE saved_services (
    id         UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id    TEXT        NOT NULL,
    service_id INTEGER     NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, service_id)
);

-- Fast lookup of all services saved by a given user
CREATE INDEX saved_services_user_id_idx ON saved_services (user_id);
