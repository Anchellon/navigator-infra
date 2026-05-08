CREATE TABLE referrals (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    TEXT NOT NULL,
    thread_id  TEXT NOT NULL,
    title      TEXT NOT NULL,
    saved      BOOLEAN NOT NULL DEFAULT FALSE,
    groups     JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_referrals_user_id   ON referrals (user_id, created_at DESC);
CREATE INDEX idx_referrals_thread_id ON referrals (thread_id);
CREATE INDEX idx_referrals_saved     ON referrals (user_id, saved, created_at DESC);
