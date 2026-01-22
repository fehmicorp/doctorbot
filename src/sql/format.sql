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
-- >>>>>>>>>>>>>>>>>>>>> FORMATS TABLES <<<<<<<<<<<<<<<<<<<<<
-- ==========================================================
CREATE SCHEMA IF NOT EXISTS format;

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