ALTER TABLE referrals
    ADD COLUMN changed_group_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN removed_group_ids JSONB NOT NULL DEFAULT '[]'::jsonb;
