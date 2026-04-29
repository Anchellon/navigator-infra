-- ============================================================
-- service_snapshots Table DDL
-- Stores denormalized service chunks with embeddings
-- Embedding model: Amazon Bedrock Titan Embeddings V2 (1024 dimensions)
-- ============================================================

-- Enable pgvector extension if not already enabled
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE public.service_snapshots (

    -- =====================
    -- Primary Key
    -- =====================
    id                          bigserial PRIMARY KEY,

    -- =====================
    -- Identity
    -- =====================
    service_id                  integer NOT NULL,
    resource_id                 integer NOT NULL,
    address_id                  integer,

    -- =====================
    -- Timestamps
    -- =====================
    verified_at                 timestamp without time zone,
    updated_at                  timestamp without time zone,

    -- =====================
    -- Location
    -- =====================
    latitude                    numeric,
    longitude                   numeric,

    -- =====================
    -- Schedule
    -- jsonb array of {day, open_mins, close_mins}
    -- Query: WHERE EXISTS (
    --   SELECT 1 FROM jsonb_array_elements(schedule) s
    --   WHERE s->>'day' = 'Monday'
    --   AND (s->>'open_mins')::int <= 870
    --   AND (s->>'close_mins')::int >= 870
    -- )
    -- =====================
    schedule                    jsonb,

    -- =====================
    -- Core Categories
    -- =====================
    category_ids                integer[],
    category_names              text[],
    sfsg_category_ids           integer[],
    sfsg_category_names         text[],

    -- =====================
    -- Eligibility by Dimension
    -- =====================
    eligibility_age             text[],
    eligibility_employment      text[],
    eligibility_ethnicity       text[],
    eligibility_family_status   text[],
    eligibility_financial       text[],
    eligibility_gender          text[],
    eligibility_health          text[],
    eligibility_immigration     text[],
    eligibility_housing         text[],
    eligibility_other           text[],
    eligibility_all             text[],

    -- =====================
    -- Prose + Embedding
    -- =====================
    embedding_text              text,
    embedding                   vector(1024)
);

-- =====================
-- Indexes
-- =====================

-- Vector similarity search (cosine distance — best for Titan V2)
CREATE INDEX service_snapshots_embedding_idx
    ON public.service_snapshots
    USING hnsw (embedding vector_cosine_ops);

-- Filtered metadata lookups
CREATE INDEX service_snapshots_service_id_idx
    ON public.service_snapshots (service_id);

CREATE INDEX service_snapshots_resource_id_idx
    ON public.service_snapshots (resource_id);

CREATE INDEX service_snapshots_category_ids_idx
    ON public.service_snapshots
    USING gin (category_ids);

CREATE INDEX service_snapshots_eligibility_all_idx
    ON public.service_snapshots
    USING gin (eligibility_all);

CREATE INDEX service_snapshots_eligibility_age_idx
    ON public.service_snapshots
    USING gin (eligibility_age);

CREATE INDEX service_snapshots_eligibility_employment_idx
    ON public.service_snapshots
    USING gin (eligibility_employment);

CREATE INDEX service_snapshots_eligibility_ethnicity_idx
    ON public.service_snapshots
    USING gin (eligibility_ethnicity);

CREATE INDEX service_snapshots_eligibility_family_status_idx
    ON public.service_snapshots
    USING gin (eligibility_family_status);

CREATE INDEX service_snapshots_eligibility_financial_idx
    ON public.service_snapshots
    USING gin (eligibility_financial);

CREATE INDEX service_snapshots_eligibility_gender_idx
    ON public.service_snapshots
    USING gin (eligibility_gender);

CREATE INDEX service_snapshots_eligibility_health_idx
    ON public.service_snapshots
    USING gin (eligibility_health);

CREATE INDEX service_snapshots_eligibility_immigration_idx
    ON public.service_snapshots
    USING gin (eligibility_immigration);

CREATE INDEX service_snapshots_eligibility_housing_idx
    ON public.service_snapshots
    USING gin (eligibility_housing);

CREATE INDEX service_snapshots_eligibility_other_idx
    ON public.service_snapshots
    USING gin (eligibility_other);

-- Geo filtering
CREATE INDEX service_snapshots_lat_lng_idx
    ON public.service_snapshots (latitude, longitude);

-- Schedule filtering (jsonb)
CREATE INDEX service_snapshots_schedule_idx
    ON public.service_snapshots
    USING gin (schedule);