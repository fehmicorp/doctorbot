-- ==========================================================
-- FEHMI SINGLE SIGN ON: AUTHENTICATION SCHEMA
-- Version: 2026.1.1
-- ==========================================================

-- 1. EXTENSIONS & SCHEMAS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS profile;

-- ==========================================================
-- >>>>>>>>>>>>>>>>>>> PUBLIC ANCHOR TABLES <<<<<<<<<<<<<<<<<
-- ==========================================================

-- 1. CENTRAL USER TABLE
CREATE TABLE IF NOT EXISTS public.user (
    user_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name VARCHAR(100),
    name CITEXT,
    avatar TEXT,
    email CITEXT UNIQUE,
    phone CITEXT UNIQUE,
    date_of_birth DATE,
    gender VARCHAR(1) CHECK (gender IN ('M', 'F', 'O')),
    status_code SMALLINT DEFAULT 1,
    last_login_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. API CLIENTS TABLE
CREATE TABLE IF NOT EXISTS public.api (
    client_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    client_name TEXT NOT NULL,
    client_secret TEXT NOT NULL,
    redirect_uris TEXT[],
    fields JSONB DEFAULT '[]', -- [name, email, phone, etc]
    scopes TEXT[], -- e.g., 'read', 'write'
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);


-- 3. AVATARS TABLE
CREATE TABLE IF NOT EXISTS public.avatars (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.credentials(user_id) ON DELETE CASCADE,
    type VARCHAR(20) CHECK (type IN ('profile', 'orgz', 'other')) DEFAULT 'profile',
    title TEXT DEFAULT 'untitled',
    is_primary BOOLEAN DEFAULT FALSE,
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. DATES TABLE
CREATE TABLE IF NOT EXISTS profile.date (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(user_id) ON DELETE CASCADE,
    date_type VARCHAR(20) CHECK (date_type IN ('dob', 'anv', 'doj', 'dol')),
    date_value DATE,
    date_format UUID REFERENCES public.date_format(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 5. ADDRESS TABLE
CREATE TABLE IF NOT EXISTS public.address (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(user_id) ON DELETE CASCADE,
    address_type VARCHAR(20) CHECK (address_type IN ('home', 'work', 'other')),
    line1 TEXT DEFAULT NULL,
    line2 TEXT DEFAULT NULL,
    street TEXT,
    city TEXT,
    state TEXT,
    zip_code TEXT,
    country TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================================
-- >>>>>>>>>>>>>>>>>>>> AUTH ANCHOR TABLES <<<<<<<<<<<<<<<<<<
-- ==========================================================

-- 1. CORE AUTHENTICATION
CREATE TABLE IF NOT EXISTS auth.credentials (
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    password_hash TEXT DEFAULT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. IDENTITIES (Email, Phone, OAuth)
CREATE TABLE IF NOT EXISTS auth.identities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(user_id) ON DELETE CASCADE,
    identity_type VARCHAR(10) CHECK (identity_type IN ("email", "phone", "username", "oauth")),
    identifier CITEXT NOT NULL,
    provider VARCHAR(20) DEFAULT "local",
    provider_id TEXT,
    is_verified BOOLEAN DEFAULT FALSE,
    is_primary BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(identity_type, identifier, provider)
);

-- 3. MFA, SESSIONS, & LOGGING
CREATE TABLE IF NOT EXISTS auth.mfa (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    mfa_enabled BOOLEAN DEFAULT FALSE,
    mfa_type VARCHAR(20) CHECK (mfa_type IN ("totp", "sms", "email")),
    secret TEXT NOT NULL,
    recovery_codes TEXT[],
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. SESSION MANAGEMENT (With Revocation)
CREATE TABLE IF NOT EXISTS auth.sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    refresh_token TEXT UNIQUE NOT NULL,
    user_agent TEXT,
    ip_address INET,
    is_revoked BOOLEAN DEFAULT FALSE,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);


-- 5. AUDIT & LOGGING
CREATE TABLE IF NOT EXISTS auth.login_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    login_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    logout_at TIMESTAMP WITH TIME ZONE,
    ip_address INET,
    user_agent TEXT,
    success BOOLEAN DEFAULT TRUE,
    failure_reason TEXT,
    metadata JSONB DEFAULT "{}"
);

-- 6. MOBILE NUMBER VERIFICATIONS & SECURITY
CREATE TABLE IF NOT EXISTS auth.mobile_number_verifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    verification_code TEXT,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    verified BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 7. MOBILE DEVICE REGISTRATIONS
CREATE TABLE auth.mobile_device_registrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    device_token TEXT UNIQUE NOT NULL,
    device_type VARCHAR(20) CHECK (device_type IN ("ios", "android")),
    registered_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_location JSONB,
    last_used_at TIMESTAMP WITH TIME ZONE
);

-- 8. SECURITY QUESTIONS
CREATE TABLE IF NOT EXISTS auth.security_questions (
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    question TEXT[] NOT NULL,
    answer_hash TEXT[] NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================================
-- >>>>>>>>>>>>>>>>>>> PROFILE ANCHOR TABLES <<<<<<<<<<<<<<<<
-- ==========================================================

-- 1. USER PROFILE DETAILS
CREATE TABLE IF NOT EXISTS profile.personal (
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    full_name VARCHAR(100),
    name JSONB, -- Stores { "first": "", "last": "" }
    avatar UUID REFERENCES public.avatars(id) ON DELETE SET NULL,
    gender VARCHAR(1) CHECK (gender IN ('M', 'F', 'O')),
    date_of_birth REFERENCES public.date(id) ON DELETE SET NULL,
    anniversary REFERENCES public.date(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. OFFICIAL PROFILE DETAILS
CREATE TABLE IF NOT EXISTS profile.official (
    user_id UUID PRIMARY KEY REFERENCES public.user(user_id) ON DELETE CASCADE,
    orgz_id UUID,
    orgz_name VARCHAR(200),
    orgz_avatar UUID,
    orgz_profile_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. DATES TABLE
CREATE TABLE IF NOT EXISTS profile.date (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(user_id) ON DELETE CASCADE,
    date_type VARCHAR(20) CHECK (date_type IN ('dob', 'anv', 'doj', 'dol')),
    date_value DATE,
    date_format UUID REFERENCES public.date_format(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================================
-- >>>>>>>>>>>>>>>>>>>>> FORMATS TABLES <<<<<<<<<<<<<<<<<<<<<
-- ==========================================================

-- 1. DATE FORMATS
CREATE TABLE IF NOT EXISTS format.date (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    date_type VARCHAR(20) CHECK (date_type IN ('short', 'long', 'custom')),
    format_string TEXT, -- e.g., 'MM-DD-YYYY'
    locale VARCHAR(10) DEFAULT 'en-IN',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. TIME FORMATS
CREATE TABLE IF NOT EXISTS format.time (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    time_type VARCHAR(20) CHECK (time_type IN ('12', '24', 'custom')),
    format_string TEXT, -- e.g., 'HH:mm:ss'
    locale VARCHAR(10) DEFAULT 'en-IN',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. NUMBER FORMATS
CREATE TABLE IF NOT EXISTS format.number (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    number_type VARCHAR(20) CHECK (number_type IN ('decimal', 'currency', 'percentage', 'custom')),
    format_string TEXT, -- e.g., '#,##0.00'
    locale VARCHAR(10) DEFAULT 'en-IN',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. CURRENCY FORMATS
CREATE TABLE IF NOT EXISTS format.currency (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    currency_code VARCHAR(3) DEFAULT 'INR',
    symbol VARCHAR(5) DEFAULT '₹',
    locale VARCHAR(10) DEFAULT 'en-IN',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 5. ADDRESS FORMATS
CREATE TABLE IF NOT EXISTS format.address (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    country_code VARCHAR(2) DEFAULT 'IN',
    format_string TEXT, -- e.g., '{street}, {city}, {state} {zip}, {country}'
    locale VARCHAR(10) DEFAULT 'en-IN',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 6. COUNTRY FORMATS
CREATE TABLE IF NOT EXISTS format.country (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    country_code VARCHAR(2) DEFAULT 'IN',
    country_name VARCHAR(100) DEFAULT 'India',
    locale VARCHAR(10) DEFAULT 'en-IN',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 7. TIMEZONE FORMATS
CREATE TABLE IF NOT EXISTS format.timezone (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    timezone_name VARCHAR(100) DEFAULT 'IST',
    utc_offset INTERVAL DEFAULT '05:30',
    locale VARCHAR(10) DEFAULT 'en-IN',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);