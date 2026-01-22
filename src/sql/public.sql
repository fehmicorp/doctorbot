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
-- CORE PUBLIC TABLES
-- ==========================================================

-- Central User Table
CREATE TABLE IF NOT EXISTS public.user (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name VARCHAR(100),
    profile_name CITEXT DEFAULT NULL UNIQUE,
    gender VARCHAR(1) CHECK (gender IN ('M', 'F', 'O')),
    status_code SMALLINT DEFAULT 1,
    last_login_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_users ON public.user(status_code, full_name, created_at);

-- Avatars (Linked to Users)
CREATE TABLE IF NOT EXISTS public.avatars (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    type VARCHAR(20) DEFAULT 'profile',
    title TEXT DEFAULT 'untitled',
    url TEXT,
    is_primary BOOLEAN DEFAULT FALSE,
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(id, user_id)
);

CREATE INDEX idx_avatar ON public.avatars(is_primary, type, user_id);

-- Organizations
CREATE TABLE IF NOT EXISTS public.orgz (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug CITEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    status_code SMALLINT DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_orgz ON public.orgz (slug, status_code);

-- CORE ORGANIZATIONAL UNITS
CREATE TABLE IF NOT EXISTS public.org_hierarchy (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    orgz_id UUID REFERENCES public.orgz(id) ON DELETE CASCADE,
    node_type VARCHAR(20) NOT NULL,
    slug CITEXT NOT NULL,
    name TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    status_code SMALLINT DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(orgz_id, slug)
);

CREATE INDEX idx_org_hierarchy_tree ON public.org_hierarchy (orgz_id, node_type);

-- DATES TABLE
CREATE TABLE IF NOT EXISTS public.date (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    date_type VARCHAR(20),
    date_value DATE,
    date_format UUID REFERENCES format.date(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, date_type)
);

CREATE INDEX idx_date ON public.date(created_at, user_id);

-- Address TABLE
CREATE TABLE IF NOT EXISTS public.address (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    address_type VARCHAR(20),
    line1 TEXT DEFAULT NULL,
    line2 TEXT DEFAULT NULL,
    street TEXT,
    city TEXT,
    state TEXT,
    zip_code TEXT,
    country TEXT,
    geo_id UUID REFERENCES public.geo_coordinates(id) ON DELETE SET NULL DEFAULT NULL,
    is_primary BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, address_type)
);

-- SOCIAL PROFILES
CREATE TABLE IF NOT EXISTS public.social (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    platform VARCHAR(20),
    url TEXT NOT NULL,
    is_verified BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, platform)
);

CREATE INDEX idx_social ON public.social(is_verified, user_id, created_at);

-- GEOSPATIAL TABLE
CREATE TABLE IF NOT EXISTS public.geo_coordinates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    orgz_id UUID REFERENCES public.orgz(id) ON DELETE CASCADE,
    slug CITEXT NOT NULL,
    geo_type VARCHAR(10), -- 'pin', 'fence', 'radius'
    geom GEOMETRY NOT NULL,
    radius_meters INTEGER DEFAULT NULL,
    status_code SMALLINT DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(orgz_id, slug)
);

CREATE INDEX idx_geoCoordinates ON public.geo_coordinates(status_code, orgz_id, created_at);


CREATE TABLE IF NOT EXISTS public.maps (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    geom GEOMETRY(Point, 4326) NOT NULL,
    altitude FLOAT,
    speed FLOAT,
    captured_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    activity_type VARCHAR(20) DEFAULT 'unknown',
    metadata JSONB DEFAULT '{}'
);

CREATE INDEX idx_maps_user_date ON public.maps (user_id, captured_at DESC);
CREATE INDEX idx_maps_geom ON public.maps USING GIST (geom);


-- SECURITY QUESTION SETS
CREATE TABLE IF NOT EXISTS public.questionsets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    orgz_id UUID REFERENCES public.orgz(id) ON DELETE CASCADE DEFAULT NULL,
    slug CITEXT NOT NULL,
    questions_sets TEXT NOT NULL,
    visibility_type VARCHAR(10) GENERATED ALWAYS AS ( CASE WHEN orgz_id IS NULL THEN 'public' ELSE 'private' END ) STORED,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_slug_per_org UNIQUE NULLS NOT DISTINCT (orgz_id, slug)
);
CREATE INDEX idx_questionsets_org_slug ON public.questionsets (orgz_id, slug);

-- ===========================================================
-- >>>>>>>>>>>>>>>>>>>>>> FUNCTIONS <<<<<<<<<<<<<<<<<<<<<<<<<<
-- ===========================================================

-- GEOMETRY HEXAGON CREATE
-- 1. GEOMETRY HEXAGON CREATE
CREATE OR REPLACE FUNCTION public.f_geo_create_hexagon(
    p_lng FLOAT, 
    p_lat FLOAT, 
    p_radius_meters FLOAT
) RETURNS GEOMETRY AS $$
    SELECT ST_SetSRID(
        ST_MakePolygon(
            ST_MakeLine(points.geom)
        ), 4326)
    FROM (
        SELECT ST_Project(
            ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, 
            p_radius_meters, 
            radians(angle)
        )::geometry AS geom
        FROM generate_series(0, 360, 60) AS angle
        ORDER BY angle
    ) AS points;
$$ LANGUAGE SQL IMMUTABLE;

-- 2. GEOMETRY SQUARE CREATE
-- Starts at 45 degrees to create a box aligned to north/south/east/west
CREATE OR REPLACE FUNCTION public.f_geo_create_square(
    p_lng FLOAT, 
    p_lat FLOAT, 
    p_radius_meters FLOAT
) RETURNS GEOMETRY AS $$
    SELECT ST_SetSRID(
        ST_MakePolygon(
            ST_MakeLine(points.geom)
        ), 4326)
    FROM (
        SELECT ST_Project(
            ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, 
            p_radius_meters, 
            radians(angle)
        )::geometry AS geom
        FROM generate_series(45, 405, 90) AS angle
        ORDER BY angle
    ) AS points;
$$ LANGUAGE SQL IMMUTABLE;

-- 3. GEOMETRY CIRCLE CREATE (High Fidelity 32-point polygon)
CREATE OR REPLACE FUNCTION public.f_geo_create_circle(
    p_lng FLOAT, 
    p_lat FLOAT, 
    p_radius_meters FLOAT
) RETURNS GEOMETRY AS $$
    SELECT ST_SetSRID(
        ST_MakePolygon(
            ST_MakeLine(points.geom)
        ), 4326)
    FROM (
        SELECT ST_Project(
            ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, 
            p_radius_meters, 
            radians(angle)
        )::geometry AS geom
        FROM generate_series(0, 360, 11.25) AS angle
        ORDER BY angle
    ) AS points;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION public.f_get_trip_path(
    p_user_id UUID,
    p_date DATE
) RETURNS TABLE (trip_path JSON) AS $$
BEGIN
    RETURN QUERY
    SELECT ST_AsGeoJSON(ST_MakeLine(geom ORDER BY captured_at))::json
    FROM public.maps
    WHERE user_id = p_user_id 
    AND captured_at::DATE = p_date;
END;
$$ LANGUAGE plpgsql;

-- SET TRIP PATH
CREATE OR REPLACE FUNCTION public.f_set_trip_path(
    p_user_id UUID,
    p_lng FLOAT,
    p_lat FLOAT,
    p_altitude FLOAT DEFAULT 0,
    p_speed FLOAT DEFAULT 0,
    p_activity VARCHAR DEFAULT 'unknown',
    p_metadata JSONB DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE
    v_new_id UUID;
BEGIN
    INSERT INTO public.maps (
        user_id, 
        geom, 
        altitude, 
        speed, 
        activity_type, 
        metadata
    )
    VALUES (
        p_user_id, 
        ST_SetSRID(ST_Point(p_lng, p_lat), 4326), 
        p_altitude, 
        p_speed, 
        p_activity, 
        p_metadata
    )
    RETURNING id INTO v_new_id;

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

-- UPDATE RUNNING DISTANCE
CREATE OR REPLACE FUNCTION public.f_update_running_distance()
RETURNS TRIGGER AS $$
DECLARE
    v_prev_point GEOMETRY;
    v_dist FLOAT;
BEGIN
    -- Find the previous point for this user
    SELECT geom INTO v_prev_point 
    FROM public.maps 
    WHERE user_id = NEW.user_id 
    AND id != NEW.id
    ORDER BY captured_at DESC LIMIT 1;

    IF v_prev_point IS NOT NULL THEN
        -- Calculate distance in meters using spheroid (high precision)
        v_dist := ST_DistanceSphere(v_prev_point, NEW.geom);
        
        -- You could store this in a 'current_trips' table or just log it
        NEW.metadata = NEW.metadata || jsonb_build_object('dist_from_last_m', v_dist);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_calculate_distance
BEFORE INSERT ON public.maps
FOR EACH ROW EXECUTE FUNCTION public.f_update_running_distance();


-- 1. ACTIVE DELIVERY/TRIP SESSIONS
CREATE TABLE IF NOT EXISTS public.active_trips (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    customer_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    
    -- Point A (Pickup/Start) and Point B (Destination)
    start_geo_id UUID REFERENCES public.geo_coordinates(id),
    end_geo_id UUID REFERENCES public.geo_coordinates(id),
    
    -- Current Status
    status VARCHAR(20),
    
    -- Real-time metrics
    current_bearing FLOAT DEFAULT 0, -- Direction the agent is facing (0-360)
    estimated_arrival TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Index for the customer to find their active delivery quickly
CREATE INDEX idx_active_trips_customer ON public.active_trips (customer_id) WHERE (status != 'TRUE');

-- UPDATE LIVE LOCATION
CREATE OR REPLACE FUNCTION public.f_update_live_location(
    p_agent_id UUID,
    p_trip_id UUID,
    p_lng FLOAT,
    p_lat FLOAT,
    p_bearing FLOAT,
    p_speed FLOAT
) RETURNS VOID AS $$
BEGIN
    -- 1. Log to the timeline (History)
    PERFORM public.set_trip_path(p_agent_id, p_lng, p_lat, 0, p_speed, 'delivery');

    -- 2. Update the Live Trip (Real-time)
    UPDATE public.active_trips 
    SET 
        current_bearing = p_bearing,
        updated_at = now()
    WHERE id = p_trip_id AND agent_id = p_agent_id;
END;
$$ LANGUAGE plpgsql;


-- ==========================================================
-- DYNAMIC SECURITY QUESTION RETRIEVAL (FULL & RANDOM)
-- ==========================================================

CREATE OR REPLACE FUNCTION public.f_get_available_questions(
    p_orgz_id UUID DEFAULT NULL,
    p_limit INTEGER DEFAULT NULL
) RETURNS TABLE (
    id UUID, 
    slug CITEXT, 
    question_text TEXT, 
    source TEXT
) AS $$
DECLARE
    v_has_private BOOLEAN;
BEGIN
    -- 1. Check if this specific organization has its own question sets
    v_has_private := EXISTS (
        SELECT 1 FROM public.questionsets 
        WHERE orgz_id = p_orgz_id
    );

    -- 2. Return questions: Private if they exist, otherwise Public (NULL)
    RETURN QUERY
    WITH question_data AS (
        SELECT 
            q.id, 
            q.slug, 
            unnest(q.questions_sets) AS q_text,
            q.visibility_type::TEXT AS v_source
        FROM public.questionsets q
        WHERE 
            (v_has_private AND q.orgz_id = p_orgz_id)
            OR 
            (NOT v_has_private AND q.orgz_id IS NULL)
    )
    SELECT * FROM question_data
    ORDER BY random()
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;