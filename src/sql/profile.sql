-- ==========================================================
-- FEHMI SINGLE SIGN ON (SSO) MASTER SCHEMA
-- Version: 2026.1.1 | Mode: Production
-- ==========================================================

-- 1. EXTENSIONS & SCHEMAS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "postgis";

-- CREATE SCHEMA IF NOT EXISTS auth;
-- CREATE SCHEMA IF NOT EXISTS profile;
-- CREATE SCHEMA IF NOT EXISTS format;
-- CREATE SCHEMA IF NOT EXISTS recovery;

-- ==========================================================
-- PROFILE TABLES
-- ==========================================================
CREATE SCHEMA IF NOT EXISTS profile;

-- USER PROFILE DETAILS
CREATE TABLE IF NOT EXISTS profile.personal (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES public.user(id) ON DELETE CASCADE,
    full_name VARCHAR(100),
    name JSONB, 
    avatar UUID REFERENCES public.avatars(id) ON DELETE SET NULL,
    gender VARCHAR(1) CHECK (gender IN ('M', 'F', 'O')),
    date_of_birth UUID REFERENCES public.date(id) ON DELETE SET NULL,
    anniversary UUID REFERENCES public.date(id) ON DELETE SET NULL,
    addresses UUID[], 
    social UUID[], 
    email UUID REFERENCES auth.identities(id) ON DELETE SET NULL,
    phone UUID REFERENCES auth.identities(id) ON DELETE SET NULL,
    orgz_id UUID REFERENCES public.orgz(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_user_profile UNIQUE(user_id)
);
CREATE INDEX idx_profile_personal_user_id ON profile.personal(user_id, orgz_id, created_at);