--
-- PostgreSQL database dump
--

-- Dumped from database version 14.16 (Homebrew)
-- Dumped by pg_dump version 14.16 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: raw_size_guides; Type: SCHEMA; Schema: -; Owner: seandavey
--

CREATE SCHEMA raw_size_guides;


ALTER SCHEMA raw_size_guides OWNER TO seandavey;

--
-- Name: calculate_body_measurement(integer, text); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.calculate_body_measurement(p_user_id integer, p_measurement_type text) RETURNS TABLE(calculated_min numeric, calculated_max numeric, confidence_score numeric)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_measurement_ranges TEXT[];
    v_weights NUMERIC[];
BEGIN
    -- Get all relevant measurements with good fit feedback
    WITH good_fit_measurements AS (
        SELECT 
            ug.chest_range,
            ug.created_at,
            b.name as brand_name,
            -- Calculate weight based on recency
            1.0 / (EXTRACT(EPOCH FROM (NOW() - ug.created_at)) / 86400.0 + 1) as recency_weight,
            -- Count consistent feedback for confidence
            COUNT(*) OVER (PARTITION BY COALESCE(uff.chest_fit, ug.fit_feedback)) as feedback_consistency
        FROM public.user_garments ug
        LEFT JOIN public.user_fit_feedback uff ON ug.id = uff.garment_id
        JOIN public.brands b ON ug.brand_id = b.id
        WHERE ug.user_id = p_user_id
        AND (
            uff.chest_fit = 'Good Fit' 
            OR ug.fit_feedback = 'Good Fit'
            OR uff.overall_fit = 'Good Fit'
        )
        AND ug.chest_range ~ '^[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)?$'
    ),
    
    -- Parse ranges and find overlaps
    parsed_ranges AS (
        SELECT 
            CAST(split_part(chest_range, '-', 1) AS NUMERIC) as range_min,
            CAST(split_part(chest_range, '-', 2) AS NUMERIC) as range_max,
            recency_weight,
            feedback_consistency
        FROM good_fit_measurements
    )
    
    -- Calculate final range based on good fit garments
    SELECT 
        MIN(range_min) as calc_min,
        MAX(range_max) as calc_max,
        -- Confidence based on number of measurements and consistency
        GREATEST(0.5, LEAST(0.95, 
            (COUNT(*)::NUMERIC / 3) * -- More measurements = higher confidence
            (SUM(feedback_consistency)::NUMERIC / (COUNT(*) * 3)) -- Consistency factor
        )) as confidence
    INTO calculated_min, calculated_max, confidence_score
    FROM parsed_ranges;

    RETURN QUERY 
    SELECT calculated_min, calculated_max, confidence_score;
END;
$_$;


ALTER FUNCTION public.calculate_body_measurement(p_user_id integer, p_measurement_type text) OWNER TO seandavey;

--
-- Name: find_garments_in_size_range(numeric, numeric); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.find_garments_in_size_range(p_min numeric, p_max numeric) RETURNS TABLE(id integer, brand_name text, size_label text, chest_range text, chest_min numeric, chest_max numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        g.id,
        g.brand_name,
        g.size_label,
        g.chest_range,
        g.chest_min,
        g.chest_max
    FROM user_garments_v2 g
    WHERE 
        -- Find garments that overlap with the given range
        g.chest_min <= p_max 
        AND g.chest_max >= p_min
    ORDER BY g.chest_min;
END;
$$;


ALTER FUNCTION public.find_garments_in_size_range(p_min numeric, p_max numeric) OWNER TO seandavey;

--
-- Name: get_brand_measurements(integer); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.get_brand_measurements(p_brand_id integer) RETURNS TABLE(measurement_name text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT m.name
    FROM (
        SELECT 'chest' as name FROM size_guides 
        WHERE brand_id = p_brand_id AND chest_range IS NOT NULL AND chest_range != 'N/A'
        UNION
        SELECT 'neck' FROM size_guides 
        WHERE brand_id = p_brand_id AND neck_range IS NOT NULL AND neck_range != 'N/A'
        UNION
        SELECT 'waist' FROM size_guides 
        WHERE brand_id = p_brand_id AND waist_range IS NOT NULL AND waist_range != 'N/A'
        UNION
        SELECT 'sleeve' FROM size_guides 
        WHERE brand_id = p_brand_id AND sleeve_range IS NOT NULL AND sleeve_range != 'N/A'
    ) m;
END;
$$;


ALTER FUNCTION public.get_brand_measurements(p_brand_id integer) OWNER TO seandavey;

--
-- Name: get_feedback_questions(integer, text); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.get_feedback_questions(p_brand_id integer, p_size_label text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_questions jsonb;
BEGIN
    SELECT jsonb_build_object(
        'overall_fit', 'How does it fit overall?',
        'chest_fit', CASE WHEN chest_range IS NOT NULL 
                    THEN 'How does it fit in the chest?' 
                    ELSE NULL END,
        'neck_fit', CASE WHEN neck_range IS NOT NULL 
                   THEN 'How does it fit in the neck?' 
                   ELSE NULL END,
        'sleeve_fit', CASE WHEN sleeve_range IS NOT NULL 
                     THEN 'How does it fit in the sleeves?' 
                   ELSE NULL END,
        'waist_fit', CASE WHEN waist_range IS NOT NULL 
                    THEN 'How does it fit in the waist?' 
                    ELSE NULL END
    ) INTO v_questions
    FROM size_guides
    WHERE brand_id = p_brand_id
    AND size_label = p_size_label;

    RETURN v_questions;
END;
$$;


ALTER FUNCTION public.get_feedback_questions(p_brand_id integer, p_size_label text) OWNER TO seandavey;

--
-- Name: get_measurement_confidence(integer); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.get_measurement_confidence(p_garment_id integer) RETURNS TABLE(measurement_type text, confidence numeric, measurement_value text, feedback_quality text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        unnest(sg.measurements_available) as measurement_type,
        CASE
            WHEN sg.data_quality = 'product_specific' THEN 0.95
            WHEN sg.data_quality = 'category_specific' THEN 0.75
            ELSE 0.5
        END *
        CASE
            WHEN uff.chest_fit IS NOT NULL THEN 1.0
            WHEN uff.overall_fit IS NOT NULL THEN 0.8
            WHEN ug.fit_feedback IS NOT NULL THEN 0.7
            ELSE 0.6
        END as confidence,
        CASE unnest(sg.measurements_available)
            WHEN 'chest' THEN sg.chest_range
            WHEN 'neck' THEN sg.neck_range
            WHEN 'sleeve' THEN sg.sleeve_range
            WHEN 'waist' THEN sg.waist_range
        END as measurement_value,
        CASE
            WHEN uff.chest_fit IS NOT NULL THEN 'Specific'
            WHEN uff.overall_fit IS NOT NULL THEN 'Overall'
            WHEN ug.fit_feedback IS NOT NULL THEN 'Basic'
            ELSE 'None'
        END as feedback_quality
    FROM user_garments ug
    JOIN size_guides sg ON ug.brand_id = sg.brand_id
    LEFT JOIN user_fit_feedback uff ON ug.id = uff.garment_id
    WHERE ug.id = p_garment_id;
END;
$$;


ALTER FUNCTION public.get_measurement_confidence(p_garment_id integer) OWNER TO seandavey;

--
-- Name: get_missing_feedback(integer); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.get_missing_feedback(p_garment_id integer) RETURNS TABLE(dimension_name text, measurement_range text, has_measurement boolean, current_feedback integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH garment_measurements AS (
        SELECT 
            g.id,
            g.brand_id,
            g.size_label,
            sg.measurements_available,
            -- Get all possible measurement ranges
            g.chest_min, g.chest_max,
            sg.sleeve_range,
            sg.neck_range,
            sg.waist_range,
            -- Get all feedback codes
            g.overall_code,
            g.chest_code,
            g.sleeve_code,
            g.neck_code,
            g.waist_code
        FROM user_garments_v2 g
        JOIN size_guides sg ON 
            sg.brand_id = g.brand_id AND 
            sg.size_label = g.size_label
        WHERE g.id = p_garment_id
    )
    SELECT 
        d.dim_name,
        d.range_value,
        d.has_measurement,
        d.feedback_code
    FROM (
        -- Overall fit (always included)
        SELECT 
            'overall' as dim_name,
            NULL as range_value,
            true as has_measurement,
            gm.overall_code as feedback_code
        FROM garment_measurements gm
        
        UNION ALL
        
        -- Chest measurements
        SELECT 
            'chest' as dim_name,
            CASE 
                WHEN gm.chest_min = gm.chest_max THEN gm.chest_min::TEXT
                ELSE gm.chest_min::TEXT || '-' || gm.chest_max::TEXT
            END as range_value,
            gm.chest_min IS NOT NULL as has_measurement,
            gm.chest_code as feedback_code
        FROM garment_measurements gm
        
        UNION ALL
        
        -- Sleeve measurements
        SELECT 
            'sleeve' as dim_name,
            gm.sleeve_range,
            gm.sleeve_range IS NOT NULL as has_measurement,
            gm.sleeve_code as feedback_code
        FROM garment_measurements gm
        
        UNION ALL
        
        -- Neck measurements
        SELECT 
            'neck' as dim_name,
            gm.neck_range,
            gm.neck_range IS NOT NULL as has_measurement,
            gm.neck_code as feedback_code
        FROM garment_measurements gm
        
        UNION ALL
        
        -- Waist measurements
        SELECT 
            'waist' as dim_name,
            gm.waist_range,
            gm.waist_range IS NOT NULL as has_measurement,
            gm.waist_code as feedback_code
        FROM garment_measurements gm
    ) d
    WHERE 
        d.has_measurement = true -- Only return dimensions we have measurements for
        AND d.feedback_code IS NULL; -- Only return dimensions missing feedback
END;
$$;


ALTER FUNCTION public.get_missing_feedback(p_garment_id integer) OWNER TO seandavey;

--
-- Name: log_garment_processing(); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.log_garment_processing() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_brand_id INTEGER;
    v_measurements JSONB;
BEGIN
    -- Log initial submission
    INSERT INTO processing_logs (input_id, step_name, step_details) VALUES (
        NEW.id,
        'input_received',
        jsonb_build_object(
            'link', NEW.product_link,
            'size', NEW.size_label,
            'user_id', NEW.user_id,
            'timestamp', NOW()
        )
    );

    -- Special case for Banana Republic
    IF NEW.product_link LIKE '%bananarepublic.gap.com%' THEN
        SELECT id INTO v_brand_id
        FROM brands 
        WHERE LOWER(name) = 'banana republic';
    ELSE
        -- Try to identify other brands from URL
        SELECT id INTO v_brand_id 
        FROM brands 
        WHERE NEW.product_link LIKE '%' || LOWER(name) || '%';
    END IF;

    -- Log brand identification attempt
    INSERT INTO processing_logs (input_id, step_name, step_details) VALUES (
        NEW.id,
        'brand_identification',
        jsonb_build_object(
            'brand_id', v_brand_id,
            'url_pattern', NEW.product_link,
            'success', v_brand_id IS NOT NULL,
            'matched_brand', (SELECT name FROM brands WHERE id = v_brand_id),
            'user_id', NEW.user_id
        )
    );

    -- Update the brand_id in user_garment_inputs
    IF v_brand_id IS NOT NULL THEN
        UPDATE user_garment_inputs 
        SET brand_id = v_brand_id 
        WHERE id = NEW.id;

        -- Get measurements for this brand and size
        SELECT jsonb_build_object(
            'chest_range', chest_range,
            'neck_range', neck_range,
            'sleeve_range', sleeve_range,
            'waist_range', waist_range
        ) INTO v_measurements
        FROM size_guides
        WHERE brand_id = v_brand_id 
        AND size_label = NEW.size_label;

        -- Log measurements found
        INSERT INTO processing_logs (input_id, step_name, step_details) VALUES (
            NEW.id,
            'measurements_retrieved',
            jsonb_build_object(
                'measurements', v_measurements,
                'size_label', NEW.size_label,
                'user_id', NEW.user_id
            )
        );
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.log_garment_processing() OWNER TO seandavey;

--
-- Name: parse_chest_range(text); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.parse_chest_range(range_str text) RETURNS TABLE(min_val numeric, max_val numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Handle single values (e.g., "47")
    IF range_str NOT LIKE '%-%' THEN
        RETURN QUERY SELECT range_str::NUMERIC, range_str::NUMERIC;
    -- Handle ranges (e.g., "41-44" or "36.0-38.0")
    ELSE
        RETURN QUERY 
        SELECT 
            SPLIT_PART(range_str, '-', 1)::NUMERIC,
            SPLIT_PART(range_str, '-', 2)::NUMERIC;
    END IF;
END;
$$;


ALTER FUNCTION public.parse_chest_range(range_str text) OWNER TO seandavey;

--
-- Name: parse_measurement_range(text); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.parse_measurement_range(range_str text) RETURNS TABLE(min_val numeric, max_val numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF range_str IS NULL THEN
        RETURN QUERY SELECT NULL::NUMERIC, NULL::NUMERIC;
    -- Handle single values (e.g., "14")
    ELSIF range_str NOT LIKE '%-%' THEN
        RETURN QUERY SELECT range_str::NUMERIC, range_str::NUMERIC;
    -- Handle ranges (e.g., "14-14.5" or "41-44")
    ELSE
        RETURN QUERY 
        SELECT 
            SPLIT_PART(range_str, '-', 1)::NUMERIC,
            SPLIT_PART(range_str, '-', 2)::NUMERIC;
    END IF;
END;
$$;


ALTER FUNCTION public.parse_measurement_range(range_str text) OWNER TO seandavey;

--
-- Name: process_garment_with_feedback(text, text, integer, json); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.process_garment_with_feedback(p_product_link text, p_size_label text, p_user_id integer, p_feedback json) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_brand_id INTEGER;
    v_garment_id INTEGER;
    v_measurement TEXT;
    v_feedback_value INTEGER;
BEGIN
    -- Extract brand name from product link and get brand_id
    -- Special case for Banana Republic
    IF p_product_link LIKE '%bananarepublic.gap.com%' THEN
        SELECT id INTO v_brand_id
        FROM brands b
        WHERE LOWER(b.name) = 'banana republic';
    ELSE
        WITH brand_extract AS (
            SELECT regexp_matches(p_product_link, '(?:www\.|//)([^/]+)') AS brand_domain
        )
        SELECT id INTO v_brand_id
        FROM brands b
        WHERE LOWER(b.name) = LOWER((SELECT brand_domain[1] FROM brand_extract));
    END IF;

    IF v_brand_id IS NULL THEN
        RAISE EXCEPTION 'Brand not found';
    END IF;

    -- Create user_garment entry
    INSERT INTO user_garments (
        user_id,
        brand_id,
        category,
        size_label,
        chest_range,
        product_link,
        owns_garment
    ) VALUES (
        p_user_id,
        v_brand_id,
        'Tops',
        p_size_label,
        'N/A',
        p_product_link,
        true
    ) RETURNING id INTO v_garment_id;

    -- Copy measurements from size_guides
    UPDATE user_garments ug
    SET chest_range = COALESCE(sg.chest_range, 'N/A')
    FROM size_guides sg
    WHERE ug.id = v_garment_id
    AND sg.brand_id = ug.brand_id
    AND sg.size_label = ug.size_label;

    -- Store feedback for each measurement
    FOR v_measurement, v_feedback_value IN 
        SELECT * FROM json_each_text(p_feedback)
    LOOP
        INSERT INTO fit_feedback (
            garment_id,
            measurement_name,
            feedback_value,
            created_at
        ) VALUES (
            v_garment_id,
            v_measurement,
            v_feedback_value::INTEGER,
            NOW()
        );
    END LOOP;

    RETURN v_garment_id;
END;
$$;


ALTER FUNCTION public.process_garment_with_feedback(p_product_link text, p_size_label text, p_user_id integer, p_feedback json) OWNER TO seandavey;

--
-- Name: recalculate_fit_zones(); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.recalculate_fit_zones() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
BEGIN
    WITH measurements AS (
        SELECT 
            CASE 
                WHEN ug.chest_range ~ '^[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)?$' THEN 
                    (CAST(split_part(ug.chest_range, '-', 1) AS FLOAT) + 
                     CAST(split_part(ug.chest_range, '-', 2) AS FLOAT)) / 2
                ELSE CAST(ug.chest_range AS FLOAT)
            END as chest_value,
            COALESCE(uff.chest_fit, ug.fit_feedback) as fit_type
        FROM user_garments ug
        LEFT JOIN user_fit_feedback uff ON ug.id = uff.garment_id
        WHERE ug.user_id = NEW.user_id
        AND ug.owns_garment = true
        AND ug.chest_range IS NOT NULL
    ),
    averages AS (
        SELECT 
            AVG(chest_value) FILTER (WHERE fit_type = 'Tight but I Like It') as tight_avg,
            AVG(chest_value) FILTER (WHERE fit_type = 'Good Fit') as good_avg,
            AVG(chest_value) FILTER (WHERE fit_type = 'Loose but I Like It') as loose_avg
        FROM measurements
    )
    INSERT INTO user_fit_zones (
        user_id, 
        category,
        tight_min,
        tight_max,
        good_min,
        good_max,
        relaxed_min,
        relaxed_max
    )
    SELECT 
        NEW.user_id,
        'Tops',
        CASE WHEN tight_avg IS NOT NULL THEN tight_avg * 0.97 ELSE NULL END,
        CASE WHEN tight_avg IS NOT NULL THEN tight_avg * 1.00 ELSE NULL END,
        CASE WHEN good_avg IS NOT NULL THEN good_avg * 0.97 ELSE 40.0 END,
        CASE WHEN good_avg IS NOT NULL THEN good_avg * 1.03 ELSE 42.0 END,
        CASE WHEN loose_avg IS NOT NULL THEN loose_avg * 1.00 ELSE NULL END,
        CASE WHEN loose_avg IS NOT NULL THEN loose_avg * 1.03 ELSE NULL END
    FROM averages
    ON CONFLICT (user_id, category) 
    DO UPDATE SET
        tight_min = EXCLUDED.tight_min,
        tight_max = EXCLUDED.tight_max,
        good_min = EXCLUDED.good_min,
        good_max = EXCLUDED.good_max,
        relaxed_min = EXCLUDED.relaxed_min,
        relaxed_max = EXCLUDED.relaxed_max;
    
    RETURN NEW;
END;
$_$;


ALTER FUNCTION public.recalculate_fit_zones() OWNER TO seandavey;

--
-- Name: refresh_metadata_on_alter_table(); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.refresh_metadata_on_alter_table() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE database_metadata
    SET columns = (
        SELECT jsonb_agg(column_name)
        FROM information_schema.columns
        WHERE table_name = database_metadata.table_name
    );
END;
$$;


ALTER FUNCTION public.refresh_metadata_on_alter_table() OWNER TO seandavey;

--
-- Name: set_garment_chest_range(integer, text); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.set_garment_chest_range(p_garment_id integer, p_range text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE user_garments_v2
    SET 
        chest_range = p_range,
        chest_min = (SELECT min_val FROM parse_chest_range(p_range)),
        chest_max = (SELECT max_val FROM parse_chest_range(p_range))
    WHERE id = p_garment_id;
END;
$$;


ALTER FUNCTION public.set_garment_chest_range(p_garment_id integer, p_range text) OWNER TO seandavey;

--
-- Name: sync_fit_feedback(); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.sync_fit_feedback() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE user_garments
    SET fit_feedback = CASE 
        WHEN NEW.overall_fit = 'Good Fit' THEN 'Good Fit'  -- Use 'Good Fit' instead of 'Perfect Fit'
        ELSE NEW.overall_fit
    END
    WHERE id = NEW.garment_id;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.sync_fit_feedback() OWNER TO seandavey;

--
-- Name: update_metadata_columns(); Type: FUNCTION; Schema: public; Owner: seandavey
--

CREATE FUNCTION public.update_metadata_columns() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE database_metadata
    SET columns = (
        SELECT jsonb_agg(column_name)
        FROM information_schema.columns
        WHERE table_name = NEW.table_name
    )
    WHERE table_name = NEW.table_name;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_metadata_columns() OWNER TO seandavey;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: automap; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.automap (
    id integer NOT NULL,
    raw_term text NOT NULL,
    standardized_term text NOT NULL,
    transform_factor numeric DEFAULT 1,
    CONSTRAINT automap_standardized_term_check CHECK ((standardized_term = ANY (ARRAY['Chest'::text, 'Sleeve Length'::text, 'Waist'::text, 'Neck'::text])))
);


ALTER TABLE public.automap OWNER TO seandavey;

--
-- Name: automap_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.automap_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.automap_id_seq OWNER TO seandavey;

--
-- Name: automap_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.automap_id_seq OWNED BY public.automap.id;


--
-- Name: brand_automap; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.brand_automap (
    id integer NOT NULL,
    raw_term text NOT NULL,
    standardized_term text NOT NULL,
    transform_factor numeric DEFAULT 1,
    mapped_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    brand_id integer
);


ALTER TABLE public.brand_automap OWNER TO seandavey;

--
-- Name: brand_automap_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.brand_automap_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.brand_automap_id_seq OWNER TO seandavey;

--
-- Name: brand_automap_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.brand_automap_id_seq OWNED BY public.brand_automap.id;


--
-- Name: brands; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.brands (
    id integer NOT NULL,
    name text NOT NULL,
    default_unit text DEFAULT 'in'::text,
    size_guide_url text,
    measurement_type character varying DEFAULT 'brand_level'::character varying,
    gender text,
    CONSTRAINT brands_default_unit_check CHECK ((default_unit = ANY (ARRAY['in'::text, 'cm'::text]))),
    CONSTRAINT brands_gender_check CHECK ((gender = ANY (ARRAY['Men'::text, 'Women'::text, 'Unisex'::text]))),
    CONSTRAINT brands_measurement_type_check CHECK (((measurement_type)::text = ANY ((ARRAY['brand_level'::character varying, 'product_level'::character varying])::text[])))
);


ALTER TABLE public.brands OWNER TO seandavey;

--
-- Name: brands_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.brands_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.brands_id_seq OWNER TO seandavey;

--
-- Name: brands_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.brands_id_seq OWNED BY public.brands.id;


--
-- Name: database_metadata; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.database_metadata (
    id integer NOT NULL,
    table_name text NOT NULL,
    description text NOT NULL,
    columns jsonb
);


ALTER TABLE public.database_metadata OWNER TO seandavey;

--
-- Name: database_metadata_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.database_metadata_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.database_metadata_id_seq OWNER TO seandavey;

--
-- Name: database_metadata_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.database_metadata_id_seq OWNED BY public.database_metadata.id;


--
-- Name: dress_category_mapping; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.dress_category_mapping (
    id integer NOT NULL,
    brand_id integer,
    brand_name text NOT NULL,
    category text NOT NULL,
    default_size_guide text,
    CONSTRAINT dress_category_mapping_default_size_guide_check CHECK ((default_size_guide = ANY (ARRAY['Numerical'::text, 'Lettered'::text])))
);


ALTER TABLE public.dress_category_mapping OWNER TO seandavey;

--
-- Name: dress_category_mapping_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.dress_category_mapping_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dress_category_mapping_id_seq OWNER TO seandavey;

--
-- Name: dress_category_mapping_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.dress_category_mapping_id_seq OWNED BY public.dress_category_mapping.id;


--
-- Name: dress_product_override; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.dress_product_override (
    id integer NOT NULL,
    product_id text NOT NULL,
    brand_id integer,
    brand_name text NOT NULL,
    category text NOT NULL,
    size_guide_override text,
    CONSTRAINT dress_product_override_size_guide_override_check CHECK ((size_guide_override = ANY (ARRAY['Numerical'::text, 'Lettered'::text])))
);


ALTER TABLE public.dress_product_override OWNER TO seandavey;

--
-- Name: dress_product_override_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.dress_product_override_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dress_product_override_id_seq OWNER TO seandavey;

--
-- Name: dress_product_override_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.dress_product_override_id_seq OWNED BY public.dress_product_override.id;


--
-- Name: dress_size_guide; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.dress_size_guide (
    id integer NOT NULL,
    brand_id integer,
    brand_name text NOT NULL,
    category text,
    size_label text NOT NULL,
    us_size text,
    fit_type text,
    unit text,
    source_url text,
    created_at timestamp without time zone DEFAULT now(),
    bust_min numeric,
    bust_max numeric,
    waist_min numeric,
    waist_max numeric,
    hip_min numeric,
    hip_max numeric,
    size_guide_type text,
    length_category text,
    dress_length_min numeric,
    dress_length_max numeric,
    high_hip_min numeric,
    high_hip_max numeric,
    low_hip_min numeric,
    low_hip_max numeric,
    CONSTRAINT dress_size_guide_category_check CHECK ((category = 'Dresses'::text)),
    CONSTRAINT dress_size_guide_fit_type_check CHECK ((fit_type = ANY (ARRAY['Regular'::text, 'Petite'::text]))),
    CONSTRAINT dress_size_guide_length_category_check CHECK ((length_category = ANY (ARRAY['Mini'::text, 'Maxi'::text, 'Regular'::text]))),
    CONSTRAINT dress_size_guide_size_guide_type_check CHECK ((size_guide_type = ANY (ARRAY['Numerical'::text, 'Lettered'::text]))),
    CONSTRAINT dress_size_guide_unit_check CHECK ((unit = ANY (ARRAY['in'::text, 'cm'::text])))
);


ALTER TABLE public.dress_size_guide OWNER TO seandavey;

--
-- Name: dress_size_guide_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.dress_size_guide_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dress_size_guide_id_seq OWNER TO seandavey;

--
-- Name: dress_size_guide_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.dress_size_guide_id_seq OWNED BY public.dress_size_guide.id;


--
-- Name: feedback_codes; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.feedback_codes (
    code integer NOT NULL,
    feedback_text text,
    feedback_type text,
    is_positive boolean
);


ALTER TABLE public.feedback_codes OWNER TO seandavey;

--
-- Name: measurement_confidence_factors; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.measurement_confidence_factors (
    id integer NOT NULL,
    factor_type text NOT NULL,
    weight numeric NOT NULL,
    CONSTRAINT valid_factor_type CHECK ((factor_type = ANY (ARRAY['recency'::text, 'feedback_consistency'::text, 'brand_reliability'::text, 'measurement_overlap'::text])))
);


ALTER TABLE public.measurement_confidence_factors OWNER TO seandavey;

--
-- Name: measurement_confidence_factors_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.measurement_confidence_factors_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.measurement_confidence_factors_id_seq OWNER TO seandavey;

--
-- Name: measurement_confidence_factors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.measurement_confidence_factors_id_seq OWNED BY public.measurement_confidence_factors.id;


--
-- Name: size_guides; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.size_guides (
    id integer NOT NULL,
    brand text NOT NULL,
    gender text,
    category text NOT NULL,
    size_label text NOT NULL,
    chest_range text,
    sleeve_range text,
    waist_range text,
    unit text,
    brand_id integer,
    neck_range text,
    hip_range text,
    data_quality text,
    measurements_available text[],
    CONSTRAINT size_guides_gender_check CHECK ((gender = ANY (ARRAY['Men'::text, 'Women'::text, 'Unisex'::text]))),
    CONSTRAINT size_guides_unit_check CHECK ((unit = ANY (ARRAY['in'::text, 'cm'::text]))),
    CONSTRAINT valid_data_quality CHECK ((data_quality = ANY (ARRAY['product_specific'::text, 'category_specific'::text, 'brand_standard'::text])))
);


ALTER TABLE public.size_guides OWNER TO seandavey;

--
-- Name: measurement_quality_analysis; Type: VIEW; Schema: public; Owner: seandavey
--

CREATE VIEW public.measurement_quality_analysis AS
 WITH measurement_counts AS (
         SELECT size_guides.brand_id,
            size_guides.category,
            size_guides.data_quality,
            array_length(size_guides.measurements_available, 1) AS measurements_count,
            size_guides.measurements_available
           FROM public.size_guides
        )
 SELECT b.id AS brand_id,
    b.name AS brand_name,
    mc.category,
    mc.data_quality,
    mc.measurements_count,
    mc.measurements_available,
        CASE
            WHEN ((mc.data_quality = 'product_specific'::text) AND (mc.measurements_count >= 3)) THEN 'High'::text
            WHEN ((mc.data_quality = 'product_specific'::text) OR (mc.measurements_count >= 3)) THEN 'Medium'::text
            ELSE 'Basic'::text
        END AS quality_tier
   FROM (measurement_counts mc
     JOIN public.brands b ON ((mc.brand_id = b.id)));


ALTER TABLE public.measurement_quality_analysis OWNER TO seandavey;

--
-- Name: men_sizeguides; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.men_sizeguides (
    id integer NOT NULL,
    brand character varying(255),
    brand_id integer,
    category character varying(255),
    size_label character varying(255),
    unit character varying(10),
    data_quality character varying(255),
    chest_min numeric(4,1),
    chest_max numeric(4,1),
    sleeve_min numeric(4,1),
    sleeve_max numeric(4,1),
    neck_min numeric(4,1),
    neck_max numeric(4,1),
    waist_min numeric(4,1),
    waist_max numeric(4,1),
    measurements_available text[]
);


ALTER TABLE public.men_sizeguides OWNER TO seandavey;

--
-- Name: men_sizeguides_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.men_sizeguides_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.men_sizeguides_id_seq OWNER TO seandavey;

--
-- Name: men_sizeguides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.men_sizeguides_id_seq OWNED BY public.men_sizeguides.id;


--
-- Name: processing_logs; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.processing_logs (
    id integer NOT NULL,
    input_id integer,
    step_name text NOT NULL,
    step_details jsonb,
    created_at timestamp without time zone DEFAULT now(),
    duration_ms integer
);


ALTER TABLE public.processing_logs OWNER TO seandavey;

--
-- Name: processing_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.processing_logs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.processing_logs_id_seq OWNER TO seandavey;

--
-- Name: processing_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.processing_logs_id_seq OWNED BY public.processing_logs.id;


--
-- Name: product_measurements; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.product_measurements (
    id integer NOT NULL,
    product_code character varying NOT NULL,
    brand_id integer,
    size character varying NOT NULL,
    chest_range character varying,
    length_range character varying,
    sleeve_range character varying,
    name character varying
);


ALTER TABLE public.product_measurements OWNER TO seandavey;

--
-- Name: product_measurements_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.product_measurements_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.product_measurements_id_seq OWNER TO seandavey;

--
-- Name: product_measurements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.product_measurements_id_seq OWNED BY public.product_measurements.id;


--
-- Name: size_guide_mappings; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.size_guide_mappings (
    id integer NOT NULL,
    brand text NOT NULL,
    size_guide_reference text NOT NULL,
    universal_category text NOT NULL
);


ALTER TABLE public.size_guide_mappings OWNER TO seandavey;

--
-- Name: size_guide_mappings_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.size_guide_mappings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.size_guide_mappings_id_seq OWNER TO seandavey;

--
-- Name: size_guide_mappings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.size_guide_mappings_id_seq OWNED BY public.size_guide_mappings.id;


--
-- Name: size_guide_sources; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.size_guide_sources (
    id integer NOT NULL,
    brand text NOT NULL,
    category text NOT NULL,
    source_url text NOT NULL,
    retrieved_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    brand_id integer,
    original_category text
);


ALTER TABLE public.size_guide_sources OWNER TO seandavey;

--
-- Name: TABLE size_guide_sources; Type: COMMENT; Schema: public; Owner: seandavey
--

COMMENT ON TABLE public.size_guide_sources IS 'Stores the original source URLs for brand size guides for traceability.';


--
-- Name: size_guide_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.size_guide_sources_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.size_guide_sources_id_seq OWNER TO seandavey;

--
-- Name: size_guide_sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.size_guide_sources_id_seq OWNED BY public.size_guide_sources.id;


--
-- Name: size_guides_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.size_guides_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.size_guides_id_seq OWNER TO seandavey;

--
-- Name: size_guides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.size_guides_id_seq OWNED BY public.size_guides.id;


--
-- Name: size_guides_v2; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.size_guides_v2 (
    id integer NOT NULL,
    brand text NOT NULL,
    brand_id integer,
    gender text NOT NULL,
    category text NOT NULL,
    size_label text NOT NULL,
    unit text NOT NULL,
    data_quality text,
    chest_min numeric(5,2),
    chest_max numeric(5,2),
    sleeve_min numeric(5,2),
    sleeve_max numeric(5,2),
    neck_min numeric(5,2),
    neck_max numeric(5,2),
    waist_min numeric(5,2),
    waist_max numeric(5,2),
    hip_min numeric(5,2),
    hip_max numeric(5,2),
    measurements_available text[],
    CONSTRAINT valid_chest_range CHECK ((chest_max >= chest_min)),
    CONSTRAINT valid_hip_range CHECK ((hip_max >= hip_min)),
    CONSTRAINT valid_neck_range CHECK ((neck_max >= neck_min)),
    CONSTRAINT valid_sleeve_range CHECK ((sleeve_max >= sleeve_min)),
    CONSTRAINT valid_waist_range CHECK ((waist_max >= waist_min))
);


ALTER TABLE public.size_guides_v2 OWNER TO seandavey;

--
-- Name: size_guides_v2_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.size_guides_v2_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.size_guides_v2_id_seq OWNER TO seandavey;

--
-- Name: size_guides_v2_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.size_guides_v2_id_seq OWNED BY public.size_guides_v2.id;


--
-- Name: universal_categories; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.universal_categories (
    id integer NOT NULL,
    category text NOT NULL
);


ALTER TABLE public.universal_categories OWNER TO seandavey;

--
-- Name: universal_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.universal_categories_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.universal_categories_id_seq OWNER TO seandavey;

--
-- Name: universal_categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.universal_categories_id_seq OWNED BY public.universal_categories.id;


--
-- Name: user_body_measurements; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.user_body_measurements (
    id integer NOT NULL,
    user_id integer,
    measurement_type text NOT NULL,
    calculated_min numeric,
    calculated_max numeric,
    confidence_score numeric,
    calculation_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    data_points integer
);


ALTER TABLE public.user_body_measurements OWNER TO seandavey;

--
-- Name: user_body_measurements_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.user_body_measurements_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_body_measurements_id_seq OWNER TO seandavey;

--
-- Name: user_body_measurements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.user_body_measurements_id_seq OWNED BY public.user_body_measurements.id;


--
-- Name: user_fit_feedback; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.user_fit_feedback (
    id integer NOT NULL,
    user_id integer NOT NULL,
    garment_id integer NOT NULL,
    overall_fit text,
    chest_fit text,
    sleeve_fit text,
    neck_fit text,
    waist_fit text,
    brand_id integer,
    brand_name character varying,
    product_name character varying,
    chest_code integer,
    shoulder_code integer,
    sleeve_code integer,
    length_code integer,
    neck_code integer,
    waist_code integer,
    CONSTRAINT user_fit_feedback_chest_fit_check CHECK ((chest_fit = ANY (ARRAY['Good Fit'::text, 'Tight but I Like It'::text, 'Too Tight'::text, 'Loose but I Like It'::text, 'Too Loose'::text]))),
    CONSTRAINT user_fit_feedback_neck_fit_check CHECK ((neck_fit = ANY (ARRAY['Too Tight'::text, 'Good Fit'::text, 'Too Loose'::text]))),
    CONSTRAINT user_fit_feedback_overall_fit_check CHECK ((overall_fit = ANY (ARRAY['Good Fit'::text, 'Too Tight'::text, 'Too Loose'::text, 'Tight but I Like It'::text, 'Loose but I Like It'::text]))),
    CONSTRAINT user_fit_feedback_sleeve_fit_check CHECK ((sleeve_fit = ANY (ARRAY['Good Fit'::text, 'Tight but I Like It'::text, 'Too Tight'::text, 'Loose but I Like It'::text, 'Too Loose'::text]))),
    CONSTRAINT user_fit_feedback_waist_fit_check CHECK ((waist_fit = ANY (ARRAY['Too Tight'::text, 'Good Fit'::text, 'Loose but I Like It'::text, 'Too Loose'::text])))
);


ALTER TABLE public.user_fit_feedback OWNER TO seandavey;

--
-- Name: user_fit_feedback_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.user_fit_feedback_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_fit_feedback_id_seq OWNER TO seandavey;

--
-- Name: user_fit_feedback_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.user_fit_feedback_id_seq OWNED BY public.user_fit_feedback.id;


--
-- Name: user_fit_zones; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.user_fit_zones (
    id integer NOT NULL,
    user_id integer NOT NULL,
    category text NOT NULL,
    tight_min numeric,
    good_min numeric,
    good_max numeric,
    relaxed_max numeric,
    tight_max numeric,
    relaxed_min numeric,
    CONSTRAINT user_fit_zones_category_check CHECK ((category = 'Tops'::text))
);


ALTER TABLE public.user_fit_zones OWNER TO seandavey;

--
-- Name: user_fit_zones_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.user_fit_zones_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_fit_zones_id_seq OWNER TO seandavey;

--
-- Name: user_fit_zones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.user_fit_zones_id_seq OWNED BY public.user_fit_zones.id;


--
-- Name: user_garment_inputs; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.user_garment_inputs (
    id integer NOT NULL,
    user_id integer,
    product_link text NOT NULL,
    size_label text NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    processed boolean DEFAULT false,
    brand_id integer,
    processing_error text,
    measurements jsonb
);


ALTER TABLE public.user_garment_inputs OWNER TO seandavey;

--
-- Name: user_garment_inputs_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.user_garment_inputs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_garment_inputs_id_seq OWNER TO seandavey;

--
-- Name: user_garment_inputs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.user_garment_inputs_id_seq OWNED BY public.user_garment_inputs.id;


--
-- Name: user_garments; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.user_garments (
    id integer NOT NULL,
    user_id integer NOT NULL,
    brand_id integer NOT NULL,
    category text NOT NULL,
    size_label text NOT NULL,
    chest_range text NOT NULL,
    fit_feedback text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    owns_garment boolean DEFAULT false NOT NULL,
    product_name text,
    product_link text,
    brand_name character varying NOT NULL,
    CONSTRAINT user_garments_category_check CHECK ((category = 'Tops'::text)),
    CONSTRAINT user_garments_fit_feedback_check CHECK ((fit_feedback = ANY (ARRAY['Too Tight'::text, 'Tight but I Like It'::text, 'Good Fit'::text, 'Loose but I Like It'::text, 'Too Loose'::text])))
);


ALTER TABLE public.user_garments OWNER TO seandavey;

--
-- Name: user_garments_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.user_garments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_garments_id_seq OWNER TO seandavey;

--
-- Name: user_garments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.user_garments_id_seq OWNED BY public.user_garments.id;


--
-- Name: user_garments_v2; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.user_garments_v2 (
    id integer NOT NULL,
    user_id integer NOT NULL,
    brand_id integer,
    brand_name text,
    category text NOT NULL,
    size_label text,
    product_name text,
    product_link text,
    owns_garment boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    overall_code integer,
    chest_code integer,
    shoulder_code integer,
    sleeve_code integer,
    length_code integer,
    neck_code integer,
    waist_code integer,
    hip_code integer,
    inseam_code integer,
    chest_min numeric(4,1),
    chest_max numeric(4,1),
    chest_range text GENERATED ALWAYS AS (
CASE
    WHEN (chest_min = chest_max) THEN (chest_min)::text
    ELSE (((chest_min)::text || '-'::text) || (chest_max)::text)
END) STORED,
    CONSTRAINT valid_chest_range CHECK ((chest_max >= chest_min))
);


ALTER TABLE public.user_garments_v2 OWNER TO seandavey;

--
-- Name: user_garments_v2_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.user_garments_v2_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_garments_v2_id_seq OWNER TO seandavey;

--
-- Name: user_garments_v2_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.user_garments_v2_id_seq OWNED BY public.user_garments_v2.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.users (
    id integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    email text,
    gender text,
    unit_preference text DEFAULT 'in'::text,
    test_column text,
    CONSTRAINT users_gender_check CHECK ((gender = ANY (ARRAY['Men'::text, 'Women'::text, 'Unisex'::text]))),
    CONSTRAINT users_unit_preference_check CHECK ((unit_preference = ANY (ARRAY['in'::text, 'cm'::text])))
);


ALTER TABLE public.users OWNER TO seandavey;

--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.users_id_seq OWNER TO seandavey;

--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: women_sizeguides; Type: TABLE; Schema: public; Owner: seandavey
--

CREATE TABLE public.women_sizeguides (
    id integer NOT NULL,
    brand character varying(255),
    brand_id integer,
    category character varying(255),
    size_label character varying(255),
    unit character varying(10),
    data_quality character varying(255),
    bust_min numeric(4,1),
    bust_max numeric(4,1),
    waist_min numeric(4,1),
    waist_max numeric(4,1),
    hip_min numeric(4,1),
    hip_max numeric(4,1),
    measurements_available text[]
);


ALTER TABLE public.women_sizeguides OWNER TO seandavey;

--
-- Name: women_sizeguides_id_seq; Type: SEQUENCE; Schema: public; Owner: seandavey
--

CREATE SEQUENCE public.women_sizeguides_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.women_sizeguides_id_seq OWNER TO seandavey;

--
-- Name: women_sizeguides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: seandavey
--

ALTER SEQUENCE public.women_sizeguides_id_seq OWNED BY public.women_sizeguides.id;


--
-- Name: automated_imports; Type: TABLE; Schema: raw_size_guides; Owner: seandavey
--

CREATE TABLE raw_size_guides.automated_imports (
    id integer NOT NULL,
    brand_name character varying,
    product_type character varying,
    department character varying,
    category character varying,
    measurements jsonb,
    unit_system character varying(8),
    image_path character varying,
    ocr_confidence double precision,
    status character varying(20) DEFAULT 'pending_review'::character varying,
    review_notes text,
    reviewed_by integer,
    reviewed_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    processed_at timestamp without time zone,
    metadata jsonb,
    brand_id integer
);


ALTER TABLE raw_size_guides.automated_imports OWNER TO seandavey;

--
-- Name: automated_imports_id_seq; Type: SEQUENCE; Schema: raw_size_guides; Owner: seandavey
--

CREATE SEQUENCE raw_size_guides.automated_imports_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE raw_size_guides.automated_imports_id_seq OWNER TO seandavey;

--
-- Name: automated_imports_id_seq; Type: SEQUENCE OWNED BY; Schema: raw_size_guides; Owner: seandavey
--

ALTER SEQUENCE raw_size_guides.automated_imports_id_seq OWNED BY raw_size_guides.automated_imports.id;


--
-- Name: automap id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.automap ALTER COLUMN id SET DEFAULT nextval('public.automap_id_seq'::regclass);


--
-- Name: brand_automap id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.brand_automap ALTER COLUMN id SET DEFAULT nextval('public.brand_automap_id_seq'::regclass);


--
-- Name: brands id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.brands ALTER COLUMN id SET DEFAULT nextval('public.brands_id_seq'::regclass);


--
-- Name: database_metadata id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.database_metadata ALTER COLUMN id SET DEFAULT nextval('public.database_metadata_id_seq'::regclass);


--
-- Name: dress_category_mapping id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_category_mapping ALTER COLUMN id SET DEFAULT nextval('public.dress_category_mapping_id_seq'::regclass);


--
-- Name: dress_product_override id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_product_override ALTER COLUMN id SET DEFAULT nextval('public.dress_product_override_id_seq'::regclass);


--
-- Name: dress_size_guide id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_size_guide ALTER COLUMN id SET DEFAULT nextval('public.dress_size_guide_id_seq'::regclass);


--
-- Name: measurement_confidence_factors id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.measurement_confidence_factors ALTER COLUMN id SET DEFAULT nextval('public.measurement_confidence_factors_id_seq'::regclass);


--
-- Name: men_sizeguides id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.men_sizeguides ALTER COLUMN id SET DEFAULT nextval('public.men_sizeguides_id_seq'::regclass);


--
-- Name: processing_logs id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.processing_logs ALTER COLUMN id SET DEFAULT nextval('public.processing_logs_id_seq'::regclass);


--
-- Name: product_measurements id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.product_measurements ALTER COLUMN id SET DEFAULT nextval('public.product_measurements_id_seq'::regclass);


--
-- Name: size_guide_mappings id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_mappings ALTER COLUMN id SET DEFAULT nextval('public.size_guide_mappings_id_seq'::regclass);


--
-- Name: size_guide_sources id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_sources ALTER COLUMN id SET DEFAULT nextval('public.size_guide_sources_id_seq'::regclass);


--
-- Name: size_guides id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guides ALTER COLUMN id SET DEFAULT nextval('public.size_guides_id_seq'::regclass);


--
-- Name: size_guides_v2 id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guides_v2 ALTER COLUMN id SET DEFAULT nextval('public.size_guides_v2_id_seq'::regclass);


--
-- Name: universal_categories id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.universal_categories ALTER COLUMN id SET DEFAULT nextval('public.universal_categories_id_seq'::regclass);


--
-- Name: user_body_measurements id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_body_measurements ALTER COLUMN id SET DEFAULT nextval('public.user_body_measurements_id_seq'::regclass);


--
-- Name: user_fit_feedback id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback ALTER COLUMN id SET DEFAULT nextval('public.user_fit_feedback_id_seq'::regclass);


--
-- Name: user_fit_zones id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_zones ALTER COLUMN id SET DEFAULT nextval('public.user_fit_zones_id_seq'::regclass);


--
-- Name: user_garment_inputs id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garment_inputs ALTER COLUMN id SET DEFAULT nextval('public.user_garment_inputs_id_seq'::regclass);


--
-- Name: user_garments id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments ALTER COLUMN id SET DEFAULT nextval('public.user_garments_id_seq'::regclass);


--
-- Name: user_garments_v2 id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2 ALTER COLUMN id SET DEFAULT nextval('public.user_garments_v2_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: women_sizeguides id; Type: DEFAULT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.women_sizeguides ALTER COLUMN id SET DEFAULT nextval('public.women_sizeguides_id_seq'::regclass);


--
-- Name: automated_imports id; Type: DEFAULT; Schema: raw_size_guides; Owner: seandavey
--

ALTER TABLE ONLY raw_size_guides.automated_imports ALTER COLUMN id SET DEFAULT nextval('raw_size_guides.automated_imports_id_seq'::regclass);


--
-- Name: automap automap_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.automap
    ADD CONSTRAINT automap_pkey PRIMARY KEY (id);


--
-- Name: automap automap_raw_term_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.automap
    ADD CONSTRAINT automap_raw_term_key UNIQUE (raw_term);


--
-- Name: brand_automap brand_automap_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.brand_automap
    ADD CONSTRAINT brand_automap_pkey PRIMARY KEY (id);


--
-- Name: brands brands_name_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_name_key UNIQUE (name);


--
-- Name: brands brands_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_pkey PRIMARY KEY (id);


--
-- Name: database_metadata database_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.database_metadata
    ADD CONSTRAINT database_metadata_pkey PRIMARY KEY (id);


--
-- Name: database_metadata database_metadata_table_name_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.database_metadata
    ADD CONSTRAINT database_metadata_table_name_key UNIQUE (table_name);


--
-- Name: dress_category_mapping dress_category_mapping_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_category_mapping
    ADD CONSTRAINT dress_category_mapping_pkey PRIMARY KEY (id);


--
-- Name: dress_product_override dress_product_override_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_product_override
    ADD CONSTRAINT dress_product_override_pkey PRIMARY KEY (id);


--
-- Name: dress_size_guide dress_size_guide_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_size_guide
    ADD CONSTRAINT dress_size_guide_pkey PRIMARY KEY (id);


--
-- Name: feedback_codes feedback_codes_feedback_text_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.feedback_codes
    ADD CONSTRAINT feedback_codes_feedback_text_key UNIQUE (feedback_text);


--
-- Name: feedback_codes feedback_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.feedback_codes
    ADD CONSTRAINT feedback_codes_pkey PRIMARY KEY (code);


--
-- Name: measurement_confidence_factors measurement_confidence_factors_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.measurement_confidence_factors
    ADD CONSTRAINT measurement_confidence_factors_pkey PRIMARY KEY (id);


--
-- Name: men_sizeguides men_sizeguides_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.men_sizeguides
    ADD CONSTRAINT men_sizeguides_pkey PRIMARY KEY (id);


--
-- Name: processing_logs processing_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.processing_logs
    ADD CONSTRAINT processing_logs_pkey PRIMARY KEY (id);


--
-- Name: product_measurements product_measurements_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.product_measurements
    ADD CONSTRAINT product_measurements_pkey PRIMARY KEY (id);


--
-- Name: product_measurements product_measurements_product_code_size_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.product_measurements
    ADD CONSTRAINT product_measurements_product_code_size_key UNIQUE (product_code, size);


--
-- Name: size_guide_mappings size_guide_mappings_brand_size_guide_reference_universal_ca_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_mappings
    ADD CONSTRAINT size_guide_mappings_brand_size_guide_reference_universal_ca_key UNIQUE (brand, size_guide_reference, universal_category);


--
-- Name: size_guide_mappings size_guide_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_mappings
    ADD CONSTRAINT size_guide_mappings_pkey PRIMARY KEY (id);


--
-- Name: size_guide_mappings size_guide_mappings_unique; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_mappings
    ADD CONSTRAINT size_guide_mappings_unique UNIQUE (brand, size_guide_reference);


--
-- Name: size_guide_sources size_guide_sources_brand_category_source_url_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_sources
    ADD CONSTRAINT size_guide_sources_brand_category_source_url_key UNIQUE (brand, category, source_url);


--
-- Name: size_guide_sources size_guide_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_sources
    ADD CONSTRAINT size_guide_sources_pkey PRIMARY KEY (id);


--
-- Name: size_guides size_guides_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guides
    ADD CONSTRAINT size_guides_pkey PRIMARY KEY (id);


--
-- Name: size_guides_v2 size_guides_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guides_v2
    ADD CONSTRAINT size_guides_v2_pkey PRIMARY KEY (id);


--
-- Name: brand_automap unique_brand_term_mapping; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.brand_automap
    ADD CONSTRAINT unique_brand_term_mapping UNIQUE (brand_id, raw_term);


--
-- Name: size_guides unique_size_guide; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guides
    ADD CONSTRAINT unique_size_guide UNIQUE (brand, gender, category, size_label);


--
-- Name: user_fit_zones unique_user_category; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_zones
    ADD CONSTRAINT unique_user_category UNIQUE (user_id, category);


--
-- Name: user_fit_feedback unique_user_garment_feedback; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT unique_user_garment_feedback UNIQUE (user_id, garment_id);


--
-- Name: user_body_measurements unique_user_measurement; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_body_measurements
    ADD CONSTRAINT unique_user_measurement UNIQUE (user_id, measurement_type);


--
-- Name: universal_categories universal_categories_category_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.universal_categories
    ADD CONSTRAINT universal_categories_category_key UNIQUE (category);


--
-- Name: universal_categories universal_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.universal_categories
    ADD CONSTRAINT universal_categories_pkey PRIMARY KEY (id);


--
-- Name: user_body_measurements user_body_measurements_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_body_measurements
    ADD CONSTRAINT user_body_measurements_pkey PRIMARY KEY (id);


--
-- Name: user_fit_feedback user_fit_feedback_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_pkey PRIMARY KEY (id);


--
-- Name: user_fit_zones user_fit_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_zones
    ADD CONSTRAINT user_fit_zones_pkey PRIMARY KEY (id);


--
-- Name: user_garment_inputs user_garment_inputs_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garment_inputs
    ADD CONSTRAINT user_garment_inputs_pkey PRIMARY KEY (id);


--
-- Name: user_garment_inputs user_garment_inputs_user_id_product_link_size_label_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garment_inputs
    ADD CONSTRAINT user_garment_inputs_user_id_product_link_size_label_key UNIQUE (user_id, product_link, size_label);


--
-- Name: user_garments user_garments_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments
    ADD CONSTRAINT user_garments_pkey PRIMARY KEY (id);


--
-- Name: user_garments_v2 user_garments_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT user_garments_v2_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: women_sizeguides women_sizeguides_pkey; Type: CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.women_sizeguides
    ADD CONSTRAINT women_sizeguides_pkey PRIMARY KEY (id);


--
-- Name: automated_imports automated_imports_pkey; Type: CONSTRAINT; Schema: raw_size_guides; Owner: seandavey
--

ALTER TABLE ONLY raw_size_guides.automated_imports
    ADD CONSTRAINT automated_imports_pkey PRIMARY KEY (id);


--
-- Name: user_garment_inputs_user_id_idx; Type: INDEX; Schema: public; Owner: seandavey
--

CREATE INDEX user_garment_inputs_user_id_idx ON public.user_garment_inputs USING btree (user_id);


--
-- Name: user_garment_inputs garment_input_trigger; Type: TRIGGER; Schema: public; Owner: seandavey
--

CREATE TRIGGER garment_input_trigger AFTER INSERT ON public.user_garment_inputs FOR EACH ROW EXECUTE FUNCTION public.log_garment_processing();


--
-- Name: user_fit_feedback update_fit_zones; Type: TRIGGER; Schema: public; Owner: seandavey
--

CREATE TRIGGER update_fit_zones AFTER INSERT OR UPDATE ON public.user_fit_feedback FOR EACH ROW EXECUTE FUNCTION public.recalculate_fit_zones();


--
-- Name: user_fit_feedback update_garment_fit_feedback; Type: TRIGGER; Schema: public; Owner: seandavey
--

CREATE TRIGGER update_garment_fit_feedback AFTER INSERT OR UPDATE ON public.user_fit_feedback FOR EACH ROW EXECUTE FUNCTION public.sync_fit_feedback();


--
-- Name: brand_automap brand_automap_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.brand_automap
    ADD CONSTRAINT brand_automap_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: dress_category_mapping dress_category_mapping_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_category_mapping
    ADD CONSTRAINT dress_category_mapping_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: dress_product_override dress_product_override_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_product_override
    ADD CONSTRAINT dress_product_override_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: dress_size_guide dress_size_guide_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.dress_size_guide
    ADD CONSTRAINT dress_size_guide_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: processing_logs processing_logs_input_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.processing_logs
    ADD CONSTRAINT processing_logs_input_id_fkey FOREIGN KEY (input_id) REFERENCES public.user_garment_inputs(id);


--
-- Name: product_measurements product_measurements_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.product_measurements
    ADD CONSTRAINT product_measurements_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: size_guide_mappings size_guide_mappings_universal_category_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_mappings
    ADD CONSTRAINT size_guide_mappings_universal_category_fkey FOREIGN KEY (universal_category) REFERENCES public.universal_categories(category);


--
-- Name: size_guide_sources size_guide_sources_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guide_sources
    ADD CONSTRAINT size_guide_sources_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: size_guides size_guides_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.size_guides
    ADD CONSTRAINT size_guides_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: user_body_measurements user_body_measurements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_body_measurements
    ADD CONSTRAINT user_body_measurements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_fit_feedback user_fit_feedback_chest_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_chest_code_fkey FOREIGN KEY (chest_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_garment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_garment_id_fkey FOREIGN KEY (garment_id) REFERENCES public.user_garments(id);


--
-- Name: user_fit_feedback user_fit_feedback_length_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_length_code_fkey FOREIGN KEY (length_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_neck_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_neck_code_fkey FOREIGN KEY (neck_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_shoulder_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_shoulder_code_fkey FOREIGN KEY (shoulder_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_sleeve_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_sleeve_code_fkey FOREIGN KEY (sleeve_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_fit_feedback user_fit_feedback_waist_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_waist_code_fkey FOREIGN KEY (waist_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_zones user_fit_zones_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_fit_zones
    ADD CONSTRAINT user_fit_zones_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_garment_inputs user_garment_inputs_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garment_inputs
    ADD CONSTRAINT user_garment_inputs_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: user_garment_inputs user_garment_inputs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garment_inputs
    ADD CONSTRAINT user_garment_inputs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_garments user_garments_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments
    ADD CONSTRAINT user_garments_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: user_garments user_garments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments
    ADD CONSTRAINT user_garments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_garments_v2 valid_chest_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_chest_code FOREIGN KEY (chest_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_hip_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_hip_code FOREIGN KEY (hip_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_inseam_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_inseam_code FOREIGN KEY (inseam_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_length_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_length_code FOREIGN KEY (length_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_neck_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_neck_code FOREIGN KEY (neck_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_overall_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_overall_code FOREIGN KEY (overall_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_shoulder_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_shoulder_code FOREIGN KEY (shoulder_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_sleeve_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_sleeve_code FOREIGN KEY (sleeve_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_waist_code; Type: FK CONSTRAINT; Schema: public; Owner: seandavey
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_waist_code FOREIGN KEY (waist_code) REFERENCES public.feedback_codes(code);


--
-- Name: automated_imports automated_imports_brand_id_fkey; Type: FK CONSTRAINT; Schema: raw_size_guides; Owner: seandavey
--

ALTER TABLE ONLY raw_size_guides.automated_imports
    ADD CONSTRAINT automated_imports_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: automated_imports automated_imports_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: raw_size_guides; Owner: seandavey
--

ALTER TABLE ONLY raw_size_guides.automated_imports
    ADD CONSTRAINT automated_imports_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);


--
-- Name: trigger_refresh_metadata; Type: EVENT TRIGGER; Schema: -; Owner: seandavey
--

CREATE EVENT TRIGGER trigger_refresh_metadata ON ddl_command_end
         WHEN TAG IN ('ALTER TABLE')
   EXECUTE FUNCTION public.refresh_metadata_on_alter_table();


ALTER EVENT TRIGGER trigger_refresh_metadata OWNER TO seandavey;

--
-- PostgreSQL database dump complete
--

