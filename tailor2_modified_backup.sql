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
-- Name: raw_size_guides; Type: SCHEMA; Schema: -; Owner: tailor2_admin
--

CREATE SCHEMA raw_size_guides;


ALTER SCHEMA raw_size_guides OWNER TO tailor2_admin;

--
-- Name: calculate_body_measurement(integer, text); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.calculate_body_measurement(p_user_id integer, p_measurement_type text) OWNER TO tailor2_admin;

--
-- Name: find_garments_in_size_range(numeric, numeric); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.find_garments_in_size_range(p_min numeric, p_max numeric) OWNER TO tailor2_admin;

--
-- Name: get_brand_measurements(integer); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.get_brand_measurements(p_brand_id integer) OWNER TO tailor2_admin;

--
-- Name: get_feedback_questions(integer, text); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.get_feedback_questions(p_brand_id integer, p_size_label text) OWNER TO tailor2_admin;

--
-- Name: get_measurement_confidence(integer); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.get_measurement_confidence(p_garment_id integer) OWNER TO tailor2_admin;

--
-- Name: get_missing_feedback(integer); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.get_missing_feedback(p_garment_id integer) OWNER TO tailor2_admin;

--
-- Name: log_garment_processing(); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.log_garment_processing() OWNER TO tailor2_admin;

--
-- Name: parse_chest_range(text); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.parse_chest_range(range_str text) OWNER TO tailor2_admin;

--
-- Name: parse_measurement_range(text); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.parse_measurement_range(range_str text) OWNER TO tailor2_admin;

--
-- Name: process_garment_with_feedback(text, text, integer, json); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.process_garment_with_feedback(p_product_link text, p_size_label text, p_user_id integer, p_feedback json) OWNER TO tailor2_admin;

--
-- Name: recalculate_fit_zones(); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.recalculate_fit_zones() OWNER TO tailor2_admin;

--
-- Name: refresh_metadata_on_alter_table(); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.refresh_metadata_on_alter_table() OWNER TO tailor2_admin;

--
-- Name: set_garment_chest_range(integer, text); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.set_garment_chest_range(p_garment_id integer, p_range text) OWNER TO tailor2_admin;

--
-- Name: sync_fit_feedback(); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.sync_fit_feedback() OWNER TO tailor2_admin;

--
-- Name: update_metadata_columns(); Type: FUNCTION; Schema: public; Owner: tailor2_admin
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


ALTER FUNCTION public.update_metadata_columns() OWNER TO tailor2_admin;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: automap; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.automap (
    id integer NOT NULL,
    raw_term text NOT NULL,
    standardized_term text NOT NULL,
    transform_factor numeric DEFAULT 1,
    CONSTRAINT automap_standardized_term_check CHECK ((standardized_term = ANY (ARRAY['Chest'::text, 'Sleeve Length'::text, 'Waist'::text, 'Neck'::text])))
);


ALTER TABLE public.automap OWNER TO tailor2_admin;

--
-- Name: automap_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.automap_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.automap_id_seq OWNER TO tailor2_admin;

--
-- Name: automap_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.automap_id_seq OWNED BY public.automap.id;


--
-- Name: brand_automap; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.brand_automap (
    id integer NOT NULL,
    raw_term text NOT NULL,
    standardized_term text NOT NULL,
    transform_factor numeric DEFAULT 1,
    mapped_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    brand_id integer
);


ALTER TABLE public.brand_automap OWNER TO tailor2_admin;

--
-- Name: brand_automap_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.brand_automap_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.brand_automap_id_seq OWNER TO tailor2_admin;

--
-- Name: brand_automap_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.brand_automap_id_seq OWNED BY public.brand_automap.id;


--
-- Name: brands; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.brands OWNER TO tailor2_admin;

--
-- Name: brands_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.brands_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.brands_id_seq OWNER TO tailor2_admin;

--
-- Name: brands_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.brands_id_seq OWNED BY public.brands.id;


--
-- Name: database_metadata; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.database_metadata (
    id integer NOT NULL,
    table_name text NOT NULL,
    description text NOT NULL,
    columns jsonb
);


ALTER TABLE public.database_metadata OWNER TO tailor2_admin;

--
-- Name: database_metadata_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.database_metadata_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.database_metadata_id_seq OWNER TO tailor2_admin;

--
-- Name: database_metadata_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.database_metadata_id_seq OWNED BY public.database_metadata.id;


--
-- Name: dress_category_mapping; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.dress_category_mapping (
    id integer NOT NULL,
    brand_id integer,
    brand_name text NOT NULL,
    category text NOT NULL,
    default_size_guide text,
    CONSTRAINT dress_category_mapping_default_size_guide_check CHECK ((default_size_guide = ANY (ARRAY['Numerical'::text, 'Lettered'::text])))
);


ALTER TABLE public.dress_category_mapping OWNER TO tailor2_admin;

--
-- Name: dress_category_mapping_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.dress_category_mapping_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dress_category_mapping_id_seq OWNER TO tailor2_admin;

--
-- Name: dress_category_mapping_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.dress_category_mapping_id_seq OWNED BY public.dress_category_mapping.id;


--
-- Name: dress_product_override; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.dress_product_override OWNER TO tailor2_admin;

--
-- Name: dress_product_override_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.dress_product_override_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dress_product_override_id_seq OWNER TO tailor2_admin;

--
-- Name: dress_product_override_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.dress_product_override_id_seq OWNED BY public.dress_product_override.id;


--
-- Name: dress_size_guide; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.dress_size_guide OWNER TO tailor2_admin;

--
-- Name: dress_size_guide_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.dress_size_guide_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dress_size_guide_id_seq OWNER TO tailor2_admin;

--
-- Name: dress_size_guide_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.dress_size_guide_id_seq OWNED BY public.dress_size_guide.id;


--
-- Name: feedback_codes; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.feedback_codes (
    code integer NOT NULL,
    feedback_text text,
    feedback_type text,
    is_positive boolean
);


ALTER TABLE public.feedback_codes OWNER TO tailor2_admin;

--
-- Name: measurement_confidence_factors; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.measurement_confidence_factors (
    id integer NOT NULL,
    factor_type text NOT NULL,
    weight numeric NOT NULL,
    CONSTRAINT valid_factor_type CHECK ((factor_type = ANY (ARRAY['recency'::text, 'feedback_consistency'::text, 'brand_reliability'::text, 'measurement_overlap'::text])))
);


ALTER TABLE public.measurement_confidence_factors OWNER TO tailor2_admin;

--
-- Name: measurement_confidence_factors_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.measurement_confidence_factors_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.measurement_confidence_factors_id_seq OWNER TO tailor2_admin;

--
-- Name: measurement_confidence_factors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.measurement_confidence_factors_id_seq OWNED BY public.measurement_confidence_factors.id;


--
-- Name: size_guides; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.size_guides OWNER TO tailor2_admin;

--
-- Name: measurement_quality_analysis; Type: VIEW; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.measurement_quality_analysis OWNER TO tailor2_admin;

--
-- Name: men_sizeguides; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.men_sizeguides OWNER TO tailor2_admin;

--
-- Name: men_sizeguides_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.men_sizeguides_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.men_sizeguides_id_seq OWNER TO tailor2_admin;

--
-- Name: men_sizeguides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.men_sizeguides_id_seq OWNED BY public.men_sizeguides.id;


--
-- Name: processing_logs; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.processing_logs (
    id integer NOT NULL,
    input_id integer,
    step_name text NOT NULL,
    step_details jsonb,
    created_at timestamp without time zone DEFAULT now(),
    duration_ms integer
);


ALTER TABLE public.processing_logs OWNER TO tailor2_admin;

--
-- Name: processing_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.processing_logs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.processing_logs_id_seq OWNER TO tailor2_admin;

--
-- Name: processing_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.processing_logs_id_seq OWNED BY public.processing_logs.id;


--
-- Name: product_measurements; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.product_measurements OWNER TO tailor2_admin;

--
-- Name: product_measurements_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.product_measurements_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.product_measurements_id_seq OWNER TO tailor2_admin;

--
-- Name: product_measurements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.product_measurements_id_seq OWNED BY public.product_measurements.id;


--
-- Name: size_guide_mappings; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.size_guide_mappings (
    id integer NOT NULL,
    brand text NOT NULL,
    size_guide_reference text NOT NULL,
    universal_category text NOT NULL
);


ALTER TABLE public.size_guide_mappings OWNER TO tailor2_admin;

--
-- Name: size_guide_mappings_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.size_guide_mappings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.size_guide_mappings_id_seq OWNER TO tailor2_admin;

--
-- Name: size_guide_mappings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.size_guide_mappings_id_seq OWNED BY public.size_guide_mappings.id;


--
-- Name: size_guide_sources; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.size_guide_sources OWNER TO tailor2_admin;

--
-- Name: TABLE size_guide_sources; Type: COMMENT; Schema: public; Owner: tailor2_admin
--

COMMENT ON TABLE public.size_guide_sources IS 'Stores the original source URLs for brand size guides for traceability.';


--
-- Name: size_guide_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.size_guide_sources_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.size_guide_sources_id_seq OWNER TO tailor2_admin;

--
-- Name: size_guide_sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.size_guide_sources_id_seq OWNED BY public.size_guide_sources.id;


--
-- Name: size_guides_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.size_guides_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.size_guides_id_seq OWNER TO tailor2_admin;

--
-- Name: size_guides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.size_guides_id_seq OWNED BY public.size_guides.id;


--
-- Name: size_guides_v2; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.size_guides_v2 OWNER TO tailor2_admin;

--
-- Name: size_guides_v2_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.size_guides_v2_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.size_guides_v2_id_seq OWNER TO tailor2_admin;

--
-- Name: size_guides_v2_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.size_guides_v2_id_seq OWNED BY public.size_guides_v2.id;


--
-- Name: universal_categories; Type: TABLE; Schema: public; Owner: tailor2_admin
--

CREATE TABLE public.universal_categories (
    id integer NOT NULL,
    category text NOT NULL
);


ALTER TABLE public.universal_categories OWNER TO tailor2_admin;

--
-- Name: universal_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.universal_categories_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.universal_categories_id_seq OWNER TO tailor2_admin;

--
-- Name: universal_categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.universal_categories_id_seq OWNED BY public.universal_categories.id;


--
-- Name: user_body_measurements; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.user_body_measurements OWNER TO tailor2_admin;

--
-- Name: user_body_measurements_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.user_body_measurements_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_body_measurements_id_seq OWNER TO tailor2_admin;

--
-- Name: user_body_measurements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.user_body_measurements_id_seq OWNED BY public.user_body_measurements.id;


--
-- Name: user_fit_feedback; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.user_fit_feedback OWNER TO tailor2_admin;

--
-- Name: user_fit_feedback_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.user_fit_feedback_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_fit_feedback_id_seq OWNER TO tailor2_admin;

--
-- Name: user_fit_feedback_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.user_fit_feedback_id_seq OWNED BY public.user_fit_feedback.id;


--
-- Name: user_fit_zones; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.user_fit_zones OWNER TO tailor2_admin;

--
-- Name: user_fit_zones_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.user_fit_zones_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_fit_zones_id_seq OWNER TO tailor2_admin;

--
-- Name: user_fit_zones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.user_fit_zones_id_seq OWNED BY public.user_fit_zones.id;


--
-- Name: user_garment_inputs; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.user_garment_inputs OWNER TO tailor2_admin;

--
-- Name: user_garment_inputs_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.user_garment_inputs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_garment_inputs_id_seq OWNER TO tailor2_admin;

--
-- Name: user_garment_inputs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.user_garment_inputs_id_seq OWNED BY public.user_garment_inputs.id;


--
-- Name: user_garments; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.user_garments OWNER TO tailor2_admin;

--
-- Name: user_garments_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.user_garments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_garments_id_seq OWNER TO tailor2_admin;

--
-- Name: user_garments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.user_garments_id_seq OWNED BY public.user_garments.id;


--
-- Name: user_garments_v2; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.user_garments_v2 OWNER TO tailor2_admin;

--
-- Name: user_garments_v2_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.user_garments_v2_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_garments_v2_id_seq OWNER TO tailor2_admin;

--
-- Name: user_garments_v2_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.user_garments_v2_id_seq OWNED BY public.user_garments_v2.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.users OWNER TO tailor2_admin;

--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.users_id_seq OWNER TO tailor2_admin;

--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: women_sizeguides; Type: TABLE; Schema: public; Owner: tailor2_admin
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


ALTER TABLE public.women_sizeguides OWNER TO tailor2_admin;

--
-- Name: women_sizeguides_id_seq; Type: SEQUENCE; Schema: public; Owner: tailor2_admin
--

CREATE SEQUENCE public.women_sizeguides_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.women_sizeguides_id_seq OWNER TO tailor2_admin;

--
-- Name: women_sizeguides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: tailor2_admin
--

ALTER SEQUENCE public.women_sizeguides_id_seq OWNED BY public.women_sizeguides.id;


--
-- Name: automated_imports; Type: TABLE; Schema: raw_size_guides; Owner: tailor2_admin
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


ALTER TABLE raw_size_guides.automated_imports OWNER TO tailor2_admin;

--
-- Name: automated_imports_id_seq; Type: SEQUENCE; Schema: raw_size_guides; Owner: tailor2_admin
--

CREATE SEQUENCE raw_size_guides.automated_imports_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE raw_size_guides.automated_imports_id_seq OWNER TO tailor2_admin;

--
-- Name: automated_imports_id_seq; Type: SEQUENCE OWNED BY; Schema: raw_size_guides; Owner: tailor2_admin
--

ALTER SEQUENCE raw_size_guides.automated_imports_id_seq OWNED BY raw_size_guides.automated_imports.id;


--
-- Name: automap id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.automap ALTER COLUMN id SET DEFAULT nextval('public.automap_id_seq'::regclass);


--
-- Name: brand_automap id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.brand_automap ALTER COLUMN id SET DEFAULT nextval('public.brand_automap_id_seq'::regclass);


--
-- Name: brands id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.brands ALTER COLUMN id SET DEFAULT nextval('public.brands_id_seq'::regclass);


--
-- Name: database_metadata id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.database_metadata ALTER COLUMN id SET DEFAULT nextval('public.database_metadata_id_seq'::regclass);


--
-- Name: dress_category_mapping id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_category_mapping ALTER COLUMN id SET DEFAULT nextval('public.dress_category_mapping_id_seq'::regclass);


--
-- Name: dress_product_override id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_product_override ALTER COLUMN id SET DEFAULT nextval('public.dress_product_override_id_seq'::regclass);


--
-- Name: dress_size_guide id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_size_guide ALTER COLUMN id SET DEFAULT nextval('public.dress_size_guide_id_seq'::regclass);


--
-- Name: measurement_confidence_factors id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.measurement_confidence_factors ALTER COLUMN id SET DEFAULT nextval('public.measurement_confidence_factors_id_seq'::regclass);


--
-- Name: men_sizeguides id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.men_sizeguides ALTER COLUMN id SET DEFAULT nextval('public.men_sizeguides_id_seq'::regclass);


--
-- Name: processing_logs id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.processing_logs ALTER COLUMN id SET DEFAULT nextval('public.processing_logs_id_seq'::regclass);


--
-- Name: product_measurements id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.product_measurements ALTER COLUMN id SET DEFAULT nextval('public.product_measurements_id_seq'::regclass);


--
-- Name: size_guide_mappings id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_mappings ALTER COLUMN id SET DEFAULT nextval('public.size_guide_mappings_id_seq'::regclass);


--
-- Name: size_guide_sources id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_sources ALTER COLUMN id SET DEFAULT nextval('public.size_guide_sources_id_seq'::regclass);


--
-- Name: size_guides id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guides ALTER COLUMN id SET DEFAULT nextval('public.size_guides_id_seq'::regclass);


--
-- Name: size_guides_v2 id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guides_v2 ALTER COLUMN id SET DEFAULT nextval('public.size_guides_v2_id_seq'::regclass);


--
-- Name: universal_categories id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.universal_categories ALTER COLUMN id SET DEFAULT nextval('public.universal_categories_id_seq'::regclass);


--
-- Name: user_body_measurements id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_body_measurements ALTER COLUMN id SET DEFAULT nextval('public.user_body_measurements_id_seq'::regclass);


--
-- Name: user_fit_feedback id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback ALTER COLUMN id SET DEFAULT nextval('public.user_fit_feedback_id_seq'::regclass);


--
-- Name: user_fit_zones id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_zones ALTER COLUMN id SET DEFAULT nextval('public.user_fit_zones_id_seq'::regclass);


--
-- Name: user_garment_inputs id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garment_inputs ALTER COLUMN id SET DEFAULT nextval('public.user_garment_inputs_id_seq'::regclass);


--
-- Name: user_garments id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments ALTER COLUMN id SET DEFAULT nextval('public.user_garments_id_seq'::regclass);


--
-- Name: user_garments_v2 id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2 ALTER COLUMN id SET DEFAULT nextval('public.user_garments_v2_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: women_sizeguides id; Type: DEFAULT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.women_sizeguides ALTER COLUMN id SET DEFAULT nextval('public.women_sizeguides_id_seq'::regclass);


--
-- Name: automated_imports id; Type: DEFAULT; Schema: raw_size_guides; Owner: tailor2_admin
--

ALTER TABLE ONLY raw_size_guides.automated_imports ALTER COLUMN id SET DEFAULT nextval('raw_size_guides.automated_imports_id_seq'::regclass);


--
-- Data for Name: automap; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.automap (id, raw_term, standardized_term, transform_factor) FROM stdin;
1	Hip	Waist	1
2	Arm Length	Sleeve Length	1
4	Neck	Neck	1
\.


--
-- Data for Name: brand_automap; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.brand_automap (id, raw_term, standardized_term, transform_factor, mapped_at, brand_id) FROM stdin;
3	Body Width	Chest	1	2025-02-16 22:29:01.556297	1
4	Half Chest Width	Chest	2	2025-02-16 22:29:01.556297	1
5	Hip	Waist	1	2025-02-16 22:29:01.556297	2
6	Arm Length	Sleeve Length	1	2025-02-16 22:29:01.556297	2
7	Outerwear	Tops	1	2025-02-16 22:29:01.556297	3
8	Shirts & Sweaters	Tops	1	2025-02-17 21:40:41.081715	9
9	Belt	Waist	1	2025-02-17 23:26:33.44104	9
\.


--
-- Data for Name: brands; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.brands (id, name, default_unit, size_guide_url, measurement_type, gender) FROM stdin;
1	Lululemon	in	https://shop.lululemon.com/help/size-guide/mens	brand_level	Men
2	Patagonia	in	https://www.patagonia.com/guides/size-fit/mens/	brand_level	Men
3	Theory	in	https://www.theory.com/size-guide/	brand_level	Men
7	J.Crew	in	https://www.jcrew.com/r/size-charts?srsltid=AfmBOopmMufU9TGhljM9Uk0INHw9FIiVM80iOcWazOFccAtoYsziUaW0	brand_level	Men
8	Faherty	in	https://fahertybrand.com/pages/mens-size-guide?srsltid=AfmBOop_QDvYGoAM1pPTD4GNS5JLAADZeK8a06Zmm2xE-ZfEF6PuYavg	brand_level	Men
9	Banana Republic	in	https://bananarepublic.gap.com/browse/info.do?cid=35404	brand_level	Men
10	Uniqlo	in	https://www.uniqlo.com/us/en/size-chart	product_level	Men
12	Madewell	in	\N	brand_level	Women
11	Aritzia	in	https://www.aritzia.com/us/en/size-guide	brand_level	Women
4	Free People	in	https://www.freepeople.com/help/size-guide/	brand_level	Women
\.


--
-- Data for Name: database_metadata; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.database_metadata (id, table_name, description, columns) FROM stdin;
2	size_guides	Stores raw size guide data from brands, mapped to universal categories.	["brand_id", "id", "gender", "category", "size_label", "chest_range", "sleeve_range", "waist_range", "unit", "neck_range", "hip_range", "data_quality", "measurements_available", "brand"]
10	user_fit_zones	Stores personalized fit zones for users, based on their past feedback.	["relaxed_min", "user_id", "id", "tight_min", "good_min", "good_max", "relaxed_max", "tight_max", "category"]
7	size_guide_sources	Stores references to size guide sources, including URLs for traceability.	["retrieved_at", "brand_id", "id", "original_category", "source_url", "brand", "category"]
3	fit_zones	Stores user fit preferences for recommendations.	\N
11	user_garments	Stores garments a user has scanned or added for fit tracking.	["created_at", "owns_garment", "user_id", "brand_id", "id", "product_name", "product_link", "brand_name", "category", "size_label", "chest_range", "fit_feedback"]
8	universal_categories	Stores standardized category names that all size guides map into.	["id", "category"]
12	users	Stores user accounts, including measurement profiles and preferences.	["id", "created_at", "email", "gender", "unit_preference", "test_column"]
9	user_fit_feedback	Tracks user feedback on fit (e.g., "Too Tight", "Perfect Fit", "Too Loose").	["waist_code", "user_id", "garment_id", "brand_id", "chest_code", "shoulder_code", "sleeve_code", "length_code", "neck_code", "id", "overall_fit", "chest_fit", "sleeve_fit", "neck_fit", "waist_fit", "product_name", "brand_name"]
6	brand_automap	Stores brand-specific term mappings for size guide standardization.	["id", "transform_factor", "mapped_at", "brand_id", "raw_term", "standardized_term"]
5	automap	Stores mappings of raw size guide terms to standardized terms.	["id", "transform_factor", "raw_term", "standardized_term"]
1	brands	Stores metadata about brands, including default unit and size guide URL.	["id", "name", "default_unit", "size_guide_url", "measurement_type", "gender"]
4	size_guide_mappings	Maps brand-specific size guides to universal garment categories.	["id", "brand", "size_guide_reference", "universal_category"]
\.


--
-- Data for Name: dress_category_mapping; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.dress_category_mapping (id, brand_id, brand_name, category, default_size_guide) FROM stdin;
1	1	Reformation	Long Dresses	Numerical
2	1	Reformation	Midi Dresses	Numerical
3	1	Reformation	Short Dresses	Numerical
4	1	Reformation	Linen Dresses	Numerical
5	1	Reformation	Occasion Dresses	Numerical
6	1	Reformation	Knit Dresses	Lettered
7	1	Reformation	Silk Dresses	Numerical
8	1	Reformation	White Dresses	Numerical
9	1	Reformation	Black Dresses	Numerical
\.


--
-- Data for Name: dress_product_override; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.dress_product_override (id, product_id, brand_id, brand_name, category, size_guide_override) FROM stdin;
1	1311710FDL	1	Reformation	Silk Dresses	Lettered
\.


--
-- Data for Name: dress_size_guide; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.dress_size_guide (id, brand_id, brand_name, category, size_label, us_size, fit_type, unit, source_url, created_at, bust_min, bust_max, waist_min, waist_max, hip_min, hip_max, size_guide_type, length_category, dress_length_min, dress_length_max, high_hip_min, high_hip_max, low_hip_min, low_hip_max) FROM stdin;
2	1	Reformation	Dresses	2	2	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	34	34	26	26	37	37	Lettered	\N	\N	\N	\N	\N	\N	\N
7	1	Reformation	Dresses	12	12	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	41.5	41.5	33.5	33.5	44.5	44.5	Lettered	\N	\N	\N	\N	\N	\N	\N
12	1	Reformation	Dresses	22	22	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	53	53	45.5	45.5	55.5	55.5	Lettered	\N	\N	\N	\N	\N	\N	\N
1	1	Reformation	Dresses	0	0	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	33	33	25	25	36	36	Numerical	\N	\N	\N	\N	\N	\N	\N
3	1	Reformation	Dresses	4	4	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	35	35	27	27	38	38	Numerical	\N	\N	\N	\N	\N	\N	\N
4	1	Reformation	Dresses	6	6	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	36	36	28	28	39	39	Numerical	\N	\N	\N	\N	\N	\N	\N
5	1	Reformation	Dresses	8	8	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	37.5	37.5	29.5	29.5	40.5	40.5	Numerical	\N	\N	\N	\N	\N	\N	\N
6	1	Reformation	Dresses	10	10	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	39.5	39.5	31.5	31.5	42.5	42.5	Numerical	\N	\N	\N	\N	\N	\N	\N
8	1	Reformation	Dresses	14	14	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	45	45	37.5	37.5	47.5	47.5	Numerical	\N	\N	\N	\N	\N	\N	\N
9	1	Reformation	Dresses	16	16	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	47	47	39.5	39.5	49.5	49.5	Numerical	\N	\N	\N	\N	\N	\N	\N
10	1	Reformation	Dresses	18	18	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	49	49	41.5	41.5	51.5	51.5	Numerical	\N	\N	\N	\N	\N	\N	\N
11	1	Reformation	Dresses	20	20	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	51	51	43.5	43.5	53.5	53.5	Numerical	\N	\N	\N	\N	\N	\N	\N
13	1	Reformation	Dresses	24	24	Regular	in	https://www.thereformation.com/size-guide	2025-03-08 23:21:35.888093	55	55	47.5	47.5	57.5	57.5	Numerical	\N	\N	\N	\N	\N	\N	\N
14	1	Reformation	Dresses	0P	0P	Petite	in	https://www.thereformation.com/size-guide	2025-03-08 23:22:38.867897	32.5	32.5	24.5	24.5	35.5	35.5	Numerical	\N	\N	\N	\N	\N	\N	\N
15	1	Reformation	Dresses	2P	2P	Petite	in	https://www.thereformation.com/size-guide	2025-03-08 23:22:38.867897	33.5	33.5	25.5	25.5	36.5	36.5	Numerical	\N	\N	\N	\N	\N	\N	\N
16	1	Reformation	Dresses	4P	4P	Petite	in	https://www.thereformation.com/size-guide	2025-03-08 23:22:38.867897	34.5	34.5	26.5	26.5	37.5	37.5	Numerical	\N	\N	\N	\N	\N	\N	\N
17	1	Reformation	Dresses	6P	6P	Petite	in	https://www.thereformation.com/size-guide	2025-03-08 23:22:38.867897	35.5	35.5	27.5	27.5	38.5	38.5	Numerical	\N	\N	\N	\N	\N	\N	\N
18	1	Reformation	Dresses	8P	8P	Petite	in	https://www.thereformation.com/size-guide	2025-03-08 23:22:38.867897	37	37	29	29	40	40	Numerical	\N	\N	\N	\N	\N	\N	\N
19	1	Reformation	Dresses	10P	10P	Petite	in	https://www.thereformation.com/size-guide	2025-03-08 23:22:38.867897	39	39	31	31	42	42	Numerical	\N	\N	\N	\N	\N	\N	\N
53	2	Realisation Par	Dresses	XXS	0	Regular	in	https://realisationpar.com/size-guide	2025-03-09 16:15:53.654506	28.25	29.5	23.25	26.0	32.75	33.5	Lettered	\N	33.0	45.75	\N	\N	\N	\N
54	2	Realisation Par	Dresses	XS	2	Regular	in	https://realisationpar.com/size-guide	2025-03-09 16:15:53.654506	30.25	31.5	25.25	28.0	34.75	35.5	Lettered	\N	33.5	46.0	\N	\N	\N	\N
55	2	Realisation Par	Dresses	S	4	Regular	in	https://realisationpar.com/size-guide	2025-03-09 16:15:53.654506	32.25	33.5	27.25	30.0	36.5	37.5	Lettered	\N	33.75	46.5	\N	\N	\N	\N
56	2	Realisation Par	Dresses	M	6	Regular	in	https://realisationpar.com/size-guide	2025-03-09 16:15:53.654506	34.25	35.5	29.25	32.0	38.5	39.25	Lettered	\N	34.25	46.75	\N	\N	\N	\N
57	2	Realisation Par	Dresses	L	8	Regular	in	https://realisationpar.com/size-guide	2025-03-09 16:15:53.654506	36.25	37.5	31.0	33.75	40.5	41.25	Lettered	\N	34.75	47.25	\N	\N	\N	\N
58	2	Realisation Par	Dresses	XL	10	Regular	in	https://realisationpar.com/size-guide	2025-03-09 16:47:50.952262	38.25	39.25	33.0	35.75	42.5	43.25	Lettered	\N	35.0	48.0	\N	\N	\N	\N
59	2	Realisation Par	Dresses	XXL	12	Regular	in	https://realisationpar.com/size-guide	2025-03-09 16:47:50.952262	40.25	41.25	35.0	37.75	44.5	45.25	Lettered	\N	35.5	48.5	\N	\N	\N	\N
87	4	Free People	Dresses	XXS	00	Regular	in	\N	2025-03-10 00:18:26.112743	31	32	23	24	34	34	Lettered	\N	\N	\N	\N	\N	\N	\N
88	4	Free People	Dresses	XS	0-2	Regular	in	\N	2025-03-10 00:18:26.112743	33	34	25	26	35	36	Lettered	\N	\N	\N	\N	\N	\N	\N
89	4	Free People	Dresses	S	4-6	Regular	in	\N	2025-03-10 00:18:26.112743	35	36	27	28	37	38	Lettered	\N	\N	\N	\N	\N	\N	\N
20	1	Reformation	Dresses	12P	12P	Petite	in	https://www.thereformation.com/size-guide	2025-03-08 23:22:38.867897	41	41	33	33	44	44	Numerical	\N	\N	\N	\N	\N	\N	\N
38	2	For Love and Lemons	Dresses	XXS	00	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	30.5	30.5	23.5	23.5	\N	\N	Lettered	Mini	32	32	29.5	29.5	35	35
90	4	Free People	Dresses	M	8-10	Regular	in	\N	2025-03-10 00:18:26.112743	37	38	29	30	39	40	Lettered	\N	\N	\N	\N	\N	\N	\N
91	4	Free People	Dresses	L	12-14	Regular	in	\N	2025-03-10 00:18:26.112743	39.5	41	31.5	33	41	42	Lettered	\N	\N	\N	\N	\N	\N	\N
92	4	Free People	Dresses	XL	16	Regular	in	\N	2025-03-10 00:18:26.112743	42.5	42.5	34.5	34.5	43	43	Lettered	\N	\N	\N	\N	\N	\N	\N
40	2	For Love and Lemons	Dresses	S	2	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	34	34	27	27	\N	\N	Lettered	Mini	33	33	33	33	39	39
45	2	For Love and Lemons	Dresses	XXS	00	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	30.5	30.5	23.5	23.5	\N	\N	Lettered	Maxi	57	57	29.5	29.5	35	35
46	2	For Love and Lemons	Dresses	XS	0	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	32	32	25	25	\N	\N	Lettered	Maxi	57.5	57.5	31	31	37	37
60	3	Staud	Dresses	XXS	00	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	31	31	23.5	23.5	34	34	Lettered	\N	\N	\N	\N	\N	\N	\N
61	3	Staud	Dresses	XS(0)	0	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	32	32	24.5	24.5	35	35	Lettered	\N	\N	\N	\N	\N	\N	\N
62	3	Staud	Dresses	XS(2)	2	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	33	33	25.5	25.5	36	36	Lettered	\N	\N	\N	\N	\N	\N	\N
63	3	Staud	Dresses	S(4)	4	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	34	34	26.5	26.5	37	37	Lettered	\N	\N	\N	\N	\N	\N	\N
64	3	Staud	Dresses	S(6)	6	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	35	35	27.5	27.5	38	38	Lettered	\N	\N	\N	\N	\N	\N	\N
65	3	Staud	Dresses	M(8)	8	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	36.5	36.5	29	29	39.5	39.5	Lettered	\N	\N	\N	\N	\N	\N	\N
66	3	Staud	Dresses	M(10)	10	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	38	38	30.5	30.5	41	41	Lettered	\N	\N	\N	\N	\N	\N	\N
67	3	Staud	Dresses	L(12)	12	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	39.5	39.5	32	32	42.5	42.5	Lettered	\N	\N	\N	\N	\N	\N	\N
68	3	Staud	Dresses	L(14)	14	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	41	41	33.5	33.5	44	44	Lettered	\N	\N	\N	\N	\N	\N	\N
69	3	Staud	Dresses	XL(16)	16	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	42.5	42.5	35	35	45.5	45.5	Lettered	\N	\N	\N	\N	\N	\N	\N
70	3	Staud	Dresses	1X(18)	18	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	44.5	44.5	37	37	47.5	47.5	Lettered	\N	\N	\N	\N	\N	\N	\N
71	3	Staud	Dresses	2X(20)	20	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	46.5	46.5	39	39	49.5	49.5	Lettered	\N	\N	\N	\N	\N	\N	\N
72	3	Staud	Dresses	2X(22)	22	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	49.5	49.5	42	42	52.5	52.5	Lettered	\N	\N	\N	\N	\N	\N	\N
73	3	Staud	Dresses	3X(24)	24	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	52.5	52.5	45	45	55.5	55.5	Lettered	\N	\N	\N	\N	\N	\N	\N
74	3	Staud	Dresses	3X(26)	26	Regular	in	https://staud.clothing/size-guide	2025-03-09 18:00:13.167065	55.5	55.5	48	48	58.5	58.5	Lettered	\N	\N	\N	\N	\N	\N	\N
47	2	For Love and Lemons	Dresses	S	2	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	34	34	27	27	\N	\N	Lettered	Maxi	58	58	33	33	39	39
48	2	For Love and Lemons	Dresses	M	6	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	36	36	29	29	\N	\N	Lettered	Maxi	58.5	58.5	35	35	41	41
49	2	For Love and Lemons	Dresses	L	8	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	38	38	31	31	\N	\N	Lettered	Maxi	59	59	37	37	43.5	43.5
21	2	For Love and Lemons	Dresses	XXS	00	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:21:49.175342	30.5	30.5	23.5	23.5	\N	\N	Lettered	\N	\N	\N	\N	\N	\N	\N
22	2	For Love and Lemons	Dresses	XS	0	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:21:49.175342	32	32	25	25	\N	\N	Lettered	\N	\N	\N	\N	\N	\N	\N
23	2	For Love and Lemons	Dresses	S	2	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:21:49.175342	34	34	27	27	\N	\N	Lettered	\N	\N	\N	\N	\N	\N	\N
24	2	For Love and Lemons	Dresses	M	6	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:21:49.175342	36	36	29	29	\N	\N	Lettered	\N	\N	\N	\N	\N	\N	\N
25	2	For Love and Lemons	Dresses	L	8	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:21:49.175342	38	38	31	31	\N	\N	Lettered	\N	\N	\N	\N	\N	\N	\N
26	2	For Love and Lemons	Dresses	XL	10	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:21:49.175342	40.5	40.5	33.5	33.5	\N	\N	Lettered	\N	\N	\N	\N	\N	\N	\N
27	2	For Love and Lemons	Dresses	1X	12	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:21:49.175342	43	44	35	37	\N	\N	Lettered	\N	\N	\N	\N	\N	\N	\N
28	2	For Love and Lemons	Dresses	2X	16	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:21:49.175342	45	47	38	40	\N	\N	Lettered	\N	\N	\N	\N	\N	\N	\N
32	2	For Love and Lemons	Dresses	XS	0	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:27:23.314092	32	32	25	25	\N	\N	Lettered	Mini	32	32	31	31	35	35
33	2	For Love and Lemons	Dresses	M	6	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:27:23.314092	36	36	29	29	\N	\N	Lettered	Mini	33	33	35	35	39	39
34	2	For Love and Lemons	Dresses	XL	10	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:27:23.314092	40.5	40.5	33.5	33.5	\N	\N	Lettered	Mini	34	34	39.5	39.5	43.5	43.5
42	2	For Love and Lemons	Dresses	L	8	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	38	38	31	31	\N	\N	Lettered	Mini	34	34	37	37	43.5	43.5
44	2	For Love and Lemons	Dresses	1X	12	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	43	44	35	37	\N	\N	Lettered	Mini	36.5	36.5	46	48	49	51
50	2	For Love and Lemons	Dresses	XL	10	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	40.5	40.5	33.5	33.5	\N	\N	Lettered	Maxi	59.5	59.5	39.5	39.5	46	46
51	2	For Love and Lemons	Dresses	1X	12	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	43	44	35	37	\N	\N	Lettered	Maxi	61.5	61.5	46	48	49	51
52	2	For Love and Lemons	Dresses	2X	16	Regular	in	https://www.forloveandlemons.com/size-guide	2025-03-09 00:29:50.413469	45	47	38	40	\N	\N	Lettered	Maxi	62.5	62.5	49	51	52	54
\.


--
-- Data for Name: feedback_codes; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.feedback_codes (code, feedback_text, feedback_type, is_positive) FROM stdin;
1	Good Fit	fit	t
2	Too Tight	fit	f
3	Tight but I Like It	fit	t
4	Too Loose	fit	f
5	Loose but I Like It	fit	t
6	Too Short	length	f
7	Too Long	length	f
8	Perfect Length	length	t
9	Short but I Like It	length	t
10	Long but I Like It	length	t
\.


--
-- Data for Name: measurement_confidence_factors; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.measurement_confidence_factors (id, factor_type, weight) FROM stdin;
1	recency	0.4
2	feedback_consistency	0.3
3	brand_reliability	0.2
4	measurement_overlap	0.1
\.


--
-- Data for Name: men_sizeguides; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.men_sizeguides (id, brand, brand_id, category, size_label, unit, data_quality, chest_min, chest_max, sleeve_min, sleeve_max, neck_min, neck_max, waist_min, waist_max, measurements_available) FROM stdin;
1	Theory	3	Tops	XS	in	brand_standard	34.0	36.0	33.0	33.5	\N	\N	\N	\N	{chest,sleeve}
2	Theory	3	Tops	S	in	brand_standard	36.0	38.0	33.5	34.0	\N	\N	\N	\N	{chest,sleeve}
3	Theory	3	Tops	M	in	brand_standard	38.0	40.0	34.0	34.5	\N	\N	\N	\N	{chest,sleeve}
4	Theory	3	Tops	L	in	brand_standard	40.0	42.0	34.5	35.0	\N	\N	\N	\N	{chest,sleeve}
5	Theory	3	Tops	XL	in	brand_standard	42.0	44.0	35.0	35.5	\N	\N	\N	\N	{chest,sleeve}
6	Theory	3	Tops	XXL	in	brand_standard	44.0	46.0	35.5	36.0	\N	\N	\N	\N	{chest,sleeve}
7	J.Crew	7	Tops	XS	in	brand_standard	32.0	34.0	31.0	32.0	13.0	13.5	26.0	28.0	{chest,neck,waist,sleeve}
8	J.Crew	7	Tops	S	in	brand_standard	35.0	37.0	32.0	33.0	14.0	14.5	29.0	31.0	{chest,neck,waist,sleeve}
9	J.Crew	7	Tops	M	in	brand_standard	38.0	40.0	33.0	34.0	15.0	15.5	32.0	34.0	{chest,neck,waist,sleeve}
10	J.Crew	7	Tops	L	in	brand_standard	41.0	43.0	34.0	35.0	16.0	16.5	35.0	37.0	{chest,neck,waist,sleeve}
11	J.Crew	7	Tops	XL	in	brand_standard	44.0	46.0	35.0	36.0	17.0	17.5	38.0	40.0	{chest,neck,waist,sleeve}
12	J.Crew	7	Tops	XXL	in	brand_standard	47.0	49.0	36.0	37.0	18.0	18.5	41.0	43.0	{chest,neck,waist,sleeve}
13	J.Crew	7	Tops	XXXL	in	brand_standard	50.0	52.0	36.0	37.0	18.0	18.5	44.0	45.0	{chest,neck,waist,sleeve}
14	Faherty	8	Tops	XS	in	brand_standard	34.0	36.0	32.5	33.0	14.0	14.0	26.0	28.0	{chest,neck,waist,sleeve}
15	Faherty	8	Tops	S	in	brand_standard	37.0	39.0	32.5	34.0	14.0	14.5	28.0	30.0	{chest,neck,waist,sleeve}
16	Lululemon	1	Tops	XS	in	brand_standard	35.0	36.0	\N	\N	\N	\N	\N	\N	{chest}
17	Faherty	8	Tops	M	in	brand_standard	40.0	41.0	34.0	35.0	15.0	15.5	31.0	33.0	{chest,neck,waist,sleeve}
18	Faherty	8	Tops	L	in	brand_standard	42.0	44.0	35.0	36.0	16.0	16.5	34.0	36.0	{chest,neck,waist,sleeve}
19	Faherty	8	Tops	XL	in	brand_standard	45.0	47.0	36.0	36.5	17.0	17.5	37.0	39.0	{chest,neck,waist,sleeve}
20	Faherty	8	Tops	XXL	in	brand_standard	48.0	51.0	36.5	37.0	18.0	18.5	40.0	43.0	{chest,neck,waist,sleeve}
21	Faherty	8	Tops	XXXL	in	brand_standard	52.0	54.0	37.5	38.0	19.0	19.5	44.0	47.0	{chest,neck,waist,sleeve}
22	Banana Republic	9	Tops	XXS	in	brand_standard	32.0	33.0	31.0	31.0	13.0	13.5	25.0	26.0	{chest,neck,waist,sleeve}
23	Banana Republic	9	Tops	XS	in	brand_standard	34.0	35.0	32.0	32.0	13.0	13.5	27.0	28.0	{chest,neck,waist,sleeve}
24	Lululemon	1	Tops	S	in	brand_standard	37.0	38.0	\N	\N	\N	\N	\N	\N	{chest}
25	Lululemon	1	Tops	M	in	brand_standard	39.0	40.0	\N	\N	\N	\N	\N	\N	{chest}
26	Lululemon	1	Tops	L	in	brand_standard	41.0	42.0	\N	\N	\N	\N	\N	\N	{chest}
27	Lululemon	1	Tops	XL	in	brand_standard	43.0	45.0	\N	\N	\N	\N	\N	\N	{chest}
28	Lululemon	1	Tops	XXL	in	brand_standard	46.0	48.0	\N	\N	\N	\N	\N	\N	{chest}
29	Lululemon	1	Tops	3XL	in	brand_standard	50.0	52.0	\N	\N	\N	\N	\N	\N	{chest}
30	Lululemon	1	Tops	4XL	in	brand_standard	53.0	55.0	\N	\N	\N	\N	\N	\N	{chest}
31	Lululemon	1	Tops	5XL	in	brand_standard	56.0	58.0	\N	\N	\N	\N	\N	\N	{chest}
32	Patagonia	2	Tops	XXS	in	brand_standard	33.0	33.0	30.0	30.0	\N	\N	32.0	32.0	{chest,waist,sleeve}
33	Patagonia	2	Tops	XS	in	brand_standard	35.0	35.0	32.0	32.0	\N	\N	34.0	34.0	{chest,waist,sleeve}
34	Patagonia	2	Tops	S	in	brand_standard	37.0	37.0	33.0	33.0	\N	\N	36.0	36.0	{chest,waist,sleeve}
35	Patagonia	2	Tops	M	in	brand_standard	40.0	40.0	34.0	34.0	\N	\N	39.0	39.0	{chest,waist,sleeve}
36	Patagonia	2	Tops	L	in	brand_standard	44.0	44.0	35.0	35.0	\N	\N	43.0	43.0	{chest,waist,sleeve}
37	Patagonia	2	Tops	XL	in	brand_standard	47.0	47.0	36.0	36.0	\N	\N	46.0	46.0	{chest,waist,sleeve}
38	Patagonia	2	Tops	XXL	in	brand_standard	50.0	50.0	37.0	37.0	\N	\N	49.0	49.0	{chest,waist,sleeve}
39	Patagonia	2	Tops	XXXL	in	brand_standard	56.0	56.0	37.5	37.5	\N	\N	55.0	55.0	{chest,waist,sleeve}
40	Banana Republic	9	Tops	S	in	brand_standard	36.0	37.0	33.0	33.0	14.0	14.5	29.0	31.0	{chest,neck,waist,sleeve}
41	Banana Republic	9	Tops	M	in	brand_standard	38.0	40.0	34.0	34.0	15.0	15.5	32.0	33.0	{chest,neck,waist,sleeve}
42	Banana Republic	9	Tops	L	in	brand_standard	41.0	44.0	35.0	35.0	16.0	16.5	34.0	35.0	{chest,neck,waist,sleeve}
43	Banana Republic	9	Tops	XL	in	brand_standard	45.0	48.0	35.5	35.5	17.0	17.5	36.0	37.0	{chest,neck,waist,sleeve}
44	Banana Republic	9	Tops	XXL	in	brand_standard	49.0	52.0	36.0	36.0	18.0	18.5	38.0	39.0	{chest,neck,waist,sleeve}
\.


--
-- Data for Name: processing_logs; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.processing_logs (id, input_id, step_name, step_details, created_at, duration_ms) FROM stdin;
1	1	input_received	{"link": "https://bananarepublic.gap.com/browse/product.do?pid=800139112", "size": "L", "user_id": 1}	2025-02-22 00:53:45.552723	\N
2	2	input_received	{"link": "https://bananarepublic.gap.com/browse/product.do?pid=987654321", "size": "L", "user_id": 1}	2025-02-22 00:55:35.90703	\N
3	3	input_received	{"link": "https://bananarepublic.gap.com/browse/product.do?pid=555555", "size": "XL", "user_id": 1, "timestamp": "2025-02-22T00:56:28.705116-05:00"}	2025-02-22 00:56:28.705116	\N
4	3	brand_identification	{"success": false, "brand_id": null, "url_pattern": "https://bananarepublic.gap.com/browse/product.do?pid=555555"}	2025-02-22 00:56:28.705116	\N
5	4	input_received	{"link": "https://bananarepublic.gap.com/browse/product.do?pid=666666", "size": "L", "user_id": 1, "timestamp": "2025-02-22T00:57:10.008167-05:00"}	2025-02-22 00:57:10.008167	\N
6	4	brand_identification	{"success": true, "brand_id": 9, "url_pattern": "https://bananarepublic.gap.com/browse/product.do?pid=666666", "matched_brand": "Banana Republic"}	2025-02-22 00:57:10.008167	\N
7	5	input_received	{"link": "https://bananarepublic.gap.com/browse/product.do?pid=777777", "size": "M", "user_id": 1, "timestamp": "2025-02-22T01:00:15.239772-05:00"}	2025-02-22 01:00:15.239772	\N
8	5	brand_identification	{"success": true, "user_id": 1, "brand_id": 9, "url_pattern": "https://bananarepublic.gap.com/browse/product.do?pid=777777", "matched_brand": "Banana Republic"}	2025-02-22 01:00:15.239772	\N
9	7	input_received	{"link": "https://bananarepublic.gap.com/browse/product.do?pid=777777", "size": "L", "user_id": 1, "timestamp": "2025-02-22T01:00:57.140702-05:00"}	2025-02-22 01:00:57.140702	\N
10	7	brand_identification	{"success": true, "user_id": 1, "brand_id": 9, "url_pattern": "https://bananarepublic.gap.com/browse/product.do?pid=777777", "matched_brand": "Banana Republic"}	2025-02-22 01:00:57.140702	\N
11	8	input_received	{"link": "https://bananarepublic.gap.com/browse/product.do?pid=888888", "size": "XL", "user_id": 1, "timestamp": "2025-02-22T01:01:54.011987-05:00"}	2025-02-22 01:01:54.011987	\N
12	8	brand_identification	{"success": true, "user_id": 1, "brand_id": 9, "url_pattern": "https://bananarepublic.gap.com/browse/product.do?pid=888888", "matched_brand": "Banana Republic"}	2025-02-22 01:01:54.011987	\N
13	8	measurements_retrieved	{"user_id": 1, "size_label": "XL", "measurements": {"neck_range": "17-17.5", "chest_range": "45-48", "waist_range": "36-37", "sleeve_range": "35.5"}}	2025-02-22 01:01:54.011987	\N
\.


--
-- Data for Name: product_measurements; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.product_measurements (id, product_code, brand_id, size, chest_range, length_range, sleeve_range, name) FROM stdin;
1	475352	10	L	41-44	27-28	25-26	Waffle Crew Neck T-Shirt
\.


--
-- Data for Name: size_guide_mappings; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.size_guide_mappings (id, brand, size_guide_reference, universal_category) FROM stdin;
1	Lululemon	Lululemon Tops Size Guide	Tops
2	Patagonia	Patagonia Tops Size Guide	Tops
3	Theory	Theory Outerwear Size Guide	Tops
4	Aritzia	Women Tops - Lettered	Tops
5	Aritzia	Women Tops - Numbered	Tops
9	Madewell	Women Dresses Size Guide	Dresses
\.


--
-- Data for Name: size_guide_sources; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.size_guide_sources (id, brand, category, source_url, retrieved_at, brand_id, original_category) FROM stdin;
3	Theory	Tops	https://example.com/theory-outerwear-size-guide	2025-02-17 18:53:33.516316	3	Outerwear
1	Patagonia	Tops	https://www.patagonia.com/guides/size-fit/mens/	2025-02-16 22:19:43.145262	2	Tops
2	Lululemon	Tops	https://shop.lululemon.com/help/size-guide/mens	2025-02-16 22:19:43.145262	1	Tops
4	Theory	Tops	https://www.theory.com/size-guide-page.html?srsltid=AfmBOor-EsoFfSxtOuTQaqJNLgI7GkzH1lXInwS22yot4wMxLLpWKfMA	2025-02-17 21:28:26.238059	3	Outerwear
6	J.Crew	Tops	https://www.jcrew.com/r/size-charts?srsltid=AfmBOopmMufU9TGhljM9Uk0INHw9FIiVM80iOcWazOFccAtoYsziUaW0	2025-02-17 21:33:39.213231	7	Tops
7	Faherty	Tops	https://fahertybrand.com/pages/mens-size-guide?srsltid=AfmBOop_QDvYGoAM1pPTD4GNS5JLAADZeK8a06Zmm2xE-ZfEF6PuYavg	2025-02-17 21:38:24.38961	8	Tops
8	Banana Republic	Tops	https://bananarepublic.gap.com/browse/info.do?cid=35404	2025-02-17 21:40:05.079615	9	Shirts & Sweaters
\.


--
-- Data for Name: size_guides; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.size_guides (id, brand, gender, category, size_label, chest_range, sleeve_range, waist_range, unit, brand_id, neck_range, hip_range, data_quality, measurements_available) FROM stdin;
18	Theory	Men	Tops	XS	34.0-36.0	33.0-33.5	\N	in	3	\N	\N	brand_standard	{chest,neck,sleeve,waist}
19	Theory	Men	Tops	S	36.0-38.0	33.5-34.0	\N	in	3	\N	\N	brand_standard	{chest,neck,sleeve,waist}
20	Theory	Men	Tops	M	38.0-40.0	34.0-34.5	\N	in	3	\N	\N	brand_standard	{chest,neck,sleeve,waist}
21	Theory	Men	Tops	L	40.0-42.0	34.5-35.0	\N	in	3	\N	\N	brand_standard	{chest,neck,sleeve,waist}
22	Theory	Men	Tops	XL	42.0-44.0	35.0-35.5	\N	in	3	\N	\N	brand_standard	{chest,neck,sleeve,waist}
23	Theory	Men	Tops	XXL	44.0-46.0	35.5-36.0	\N	in	3	\N	\N	brand_standard	{chest,neck,sleeve,waist}
36	J.Crew	Men	Tops	XS	32-34	31-32	26-28	in	7	13-13.5	\N	brand_standard	{chest,neck,sleeve,waist}
37	J.Crew	Men	Tops	S	35-37	32-33	29-31	in	7	14-14.5	\N	brand_standard	{chest,neck,sleeve,waist}
38	J.Crew	Men	Tops	M	38-40	33-34	32-34	in	7	15-15.5	\N	brand_standard	{chest,neck,sleeve,waist}
39	J.Crew	Men	Tops	L	41-43	34-35	35-37	in	7	16-16.5	\N	brand_standard	{chest,neck,sleeve,waist}
40	J.Crew	Men	Tops	XL	44-46	35-36	38-40	in	7	17-17.5	\N	brand_standard	{chest,neck,sleeve,waist}
41	J.Crew	Men	Tops	XXL	47-49	36-37	41-43	in	7	18-18.5	\N	brand_standard	{chest,neck,sleeve,waist}
42	J.Crew	Men	Tops	XXXL	50-52	36-37	44-45	in	7	18-18.5	\N	brand_standard	{chest,neck,sleeve,waist}
43	Faherty	Men	Tops	XS	34-36	32.5-33	26-28	in	8	14	\N	brand_standard	{chest,neck,sleeve,waist}
44	Faherty	Men	Tops	S	37-39	32.5-34	28-30	in	8	14-14.5	\N	brand_standard	{chest,neck,sleeve,waist}
1	Lululemon	Men	Tops	XS	35-36	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
45	Faherty	Men	Tops	M	40-41	34-35	31-33	in	8	15-15.5	\N	brand_standard	{chest,neck,sleeve,waist}
46	Faherty	Men	Tops	L	42-44	35-36	34-36	in	8	16-16.5	\N	brand_standard	{chest,neck,sleeve,waist}
47	Faherty	Men	Tops	XL	45-47	36-36.5	37-39	in	8	17-17.5	\N	brand_standard	{chest,neck,sleeve,waist}
48	Faherty	Men	Tops	XXL	48-51	36.5-37	40-43	in	8	18-18.5	\N	brand_standard	{chest,neck,sleeve,waist}
49	Faherty	Men	Tops	XXXL	52-54	37.5-38	44-47	in	8	19-19.5	\N	brand_standard	{chest,neck,sleeve,waist}
50	Banana Republic	Men	Tops	XXS	32-33	31	25-26	in	9	13-13.5	\N	brand_standard	{chest,neck,sleeve,waist}
51	Banana Republic	Men	Tops	XS	34-35	32	27-28	in	9	13-13.5	\N	brand_standard	{chest,neck,sleeve,waist}
2	Lululemon	Men	Tops	S	37-38	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
3	Lululemon	Men	Tops	M	39-40	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
4	Lululemon	Men	Tops	L	41-42	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
5	Lululemon	Men	Tops	XL	43-45	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
6	Lululemon	Men	Tops	XXL	46-48	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
7	Lululemon	Men	Tops	3XL	50-52	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
8	Lululemon	Men	Tops	4XL	53-55	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
9	Lululemon	Men	Tops	5XL	56-58	\N	\N	in	1	\N	\N	brand_standard	{chest,neck,sleeve,waist}
10	Patagonia	Men	Tops	XXS	33	30	32	in	2	\N	\N	brand_standard	{chest,neck,sleeve,waist}
11	Patagonia	Men	Tops	XS	35	32	34	in	2	\N	\N	brand_standard	{chest,neck,sleeve,waist}
12	Patagonia	Men	Tops	S	37	33	36	in	2	\N	\N	brand_standard	{chest,neck,sleeve,waist}
13	Patagonia	Men	Tops	M	40	34	39	in	2	\N	\N	brand_standard	{chest,neck,sleeve,waist}
14	Patagonia	Men	Tops	L	44	35	43	in	2	\N	\N	brand_standard	{chest,neck,sleeve,waist}
15	Patagonia	Men	Tops	XL	47	36	46	in	2	\N	\N	brand_standard	{chest,neck,sleeve,waist}
16	Patagonia	Men	Tops	XXL	50	37	49	in	2	\N	\N	brand_standard	{chest,neck,sleeve,waist}
17	Patagonia	Men	Tops	XXXL	56	37.5	55	in	2	\N	\N	brand_standard	{chest,neck,sleeve,waist}
52	Banana Republic	Men	Tops	S	36-37	33	29-31	in	9	14-14.5	\N	brand_standard	{chest,neck,sleeve,waist}
53	Banana Republic	Men	Tops	M	38-40	34	32-33	in	9	15-15.5	\N	brand_standard	{chest,neck,sleeve,waist}
54	Banana Republic	Men	Tops	L	41-44	35	34-35	in	9	16-16.5	\N	brand_standard	{chest,neck,sleeve,waist}
55	Banana Republic	Men	Tops	XL	45-48	35.5	36-37	in	9	17-17.5	\N	brand_standard	{chest,neck,sleeve,waist}
56	Banana Republic	Men	Tops	XXL	49-52	36	38-39	in	9	18-18.5	\N	brand_standard	{chest,neck,sleeve,waist}
57	Aritzia	Women	Undisc	2XS	30.5	\N	22.5	in	11	\N	32.5	brand_standard	{chest,neck,sleeve,waist}
58	Aritzia	Women	Undisc	XS	32-33	\N	24-25	in	11	\N	34-35	brand_standard	{chest,neck,sleeve,waist}
59	Aritzia	Women	Undisc	S	34-35	\N	26-27	in	11	\N	36-37	brand_standard	{chest,neck,sleeve,waist}
60	Aritzia	Women	Undisc	M	36-37.5	\N	28-29.75	in	11	\N	38-39.5	brand_standard	{chest,neck,sleeve,waist}
61	Aritzia	Women	Undisc	L	39-40.5	\N	31.5-33.25	in	11	\N	41-42.5	brand_standard	{chest,neck,sleeve,waist}
62	Aritzia	Women	Undisc	XL	42-43.5	\N	35-36.75	in	11	\N	44-45.5	brand_standard	{chest,neck,sleeve,waist}
63	Aritzia	Women	Undisc	XXL	45	\N	38.5	in	11	\N	47	brand_standard	{chest,neck,sleeve,waist}
64	Aritzia	Women	Undisc	00	30.5	\N	22.5	in	11	\N	32.5	brand_standard	{chest,neck,sleeve,waist}
65	Aritzia	Women	Undisc	0	32	\N	24	in	11	\N	34	brand_standard	{chest,neck,sleeve,waist}
66	Aritzia	Women	Undisc	2	33	\N	25	in	11	\N	35	brand_standard	{chest,neck,sleeve,waist}
67	Aritzia	Women	Undisc	4	34	\N	26	in	11	\N	36	brand_standard	{chest,neck,sleeve,waist}
68	Aritzia	Women	Undisc	6	35	\N	27	in	11	\N	37	brand_standard	{chest,neck,sleeve,waist}
69	Aritzia	Women	Undisc	8	36	\N	28	in	11	\N	38	brand_standard	{chest,neck,sleeve,waist}
70	Aritzia	Women	Undisc	10	37.5	\N	29.75	in	11	\N	39.5	brand_standard	{chest,neck,sleeve,waist}
71	Aritzia	Women	Undisc	12	39	\N	31.5	in	11	\N	41	brand_standard	{chest,neck,sleeve,waist}
72	Aritzia	Women	Undisc	14	40.5	\N	33.25	in	11	\N	42.5	brand_standard	{chest,neck,sleeve,waist}
73	Aritzia	Women	Undisc	16	42	\N	35	in	11	\N	44	brand_standard	{chest,neck,sleeve,waist}
\.


--
-- Data for Name: size_guides_v2; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.size_guides_v2 (id, brand, brand_id, gender, category, size_label, unit, data_quality, chest_min, chest_max, sleeve_min, sleeve_max, neck_min, neck_max, waist_min, waist_max, hip_min, hip_max, measurements_available) FROM stdin;
1	Theory	3	Men	Tops	XS	in	brand_standard	34.00	36.00	33.00	33.50	\N	\N	\N	\N	\N	\N	{chest,sleeve}
2	Theory	3	Men	Tops	S	in	brand_standard	36.00	38.00	33.50	34.00	\N	\N	\N	\N	\N	\N	{chest,sleeve}
3	Theory	3	Men	Tops	M	in	brand_standard	38.00	40.00	34.00	34.50	\N	\N	\N	\N	\N	\N	{chest,sleeve}
4	Theory	3	Men	Tops	L	in	brand_standard	40.00	42.00	34.50	35.00	\N	\N	\N	\N	\N	\N	{chest,sleeve}
5	Theory	3	Men	Tops	XL	in	brand_standard	42.00	44.00	35.00	35.50	\N	\N	\N	\N	\N	\N	{chest,sleeve}
6	Theory	3	Men	Tops	XXL	in	brand_standard	44.00	46.00	35.50	36.00	\N	\N	\N	\N	\N	\N	{chest,sleeve}
7	J.Crew	7	Men	Tops	XS	in	brand_standard	32.00	34.00	31.00	32.00	13.00	13.50	26.00	28.00	\N	\N	{chest,neck,waist,sleeve}
8	J.Crew	7	Men	Tops	S	in	brand_standard	35.00	37.00	32.00	33.00	14.00	14.50	29.00	31.00	\N	\N	{chest,neck,waist,sleeve}
9	J.Crew	7	Men	Tops	M	in	brand_standard	38.00	40.00	33.00	34.00	15.00	15.50	32.00	34.00	\N	\N	{chest,neck,waist,sleeve}
10	J.Crew	7	Men	Tops	L	in	brand_standard	41.00	43.00	34.00	35.00	16.00	16.50	35.00	37.00	\N	\N	{chest,neck,waist,sleeve}
11	J.Crew	7	Men	Tops	XL	in	brand_standard	44.00	46.00	35.00	36.00	17.00	17.50	38.00	40.00	\N	\N	{chest,neck,waist,sleeve}
12	J.Crew	7	Men	Tops	XXL	in	brand_standard	47.00	49.00	36.00	37.00	18.00	18.50	41.00	43.00	\N	\N	{chest,neck,waist,sleeve}
13	J.Crew	7	Men	Tops	XXXL	in	brand_standard	50.00	52.00	36.00	37.00	18.00	18.50	44.00	45.00	\N	\N	{chest,neck,waist,sleeve}
14	Faherty	8	Men	Tops	XS	in	brand_standard	34.00	36.00	32.50	33.00	14.00	14.00	26.00	28.00	\N	\N	{chest,neck,waist,sleeve}
15	Faherty	8	Men	Tops	S	in	brand_standard	37.00	39.00	32.50	34.00	14.00	14.50	28.00	30.00	\N	\N	{chest,neck,waist,sleeve}
16	Lululemon	1	Men	Tops	XS	in	brand_standard	35.00	36.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
17	Faherty	8	Men	Tops	M	in	brand_standard	40.00	41.00	34.00	35.00	15.00	15.50	31.00	33.00	\N	\N	{chest,neck,waist,sleeve}
18	Faherty	8	Men	Tops	L	in	brand_standard	42.00	44.00	35.00	36.00	16.00	16.50	34.00	36.00	\N	\N	{chest,neck,waist,sleeve}
19	Faherty	8	Men	Tops	XL	in	brand_standard	45.00	47.00	36.00	36.50	17.00	17.50	37.00	39.00	\N	\N	{chest,neck,waist,sleeve}
20	Faherty	8	Men	Tops	XXL	in	brand_standard	48.00	51.00	36.50	37.00	18.00	18.50	40.00	43.00	\N	\N	{chest,neck,waist,sleeve}
21	Faherty	8	Men	Tops	XXXL	in	brand_standard	52.00	54.00	37.50	38.00	19.00	19.50	44.00	47.00	\N	\N	{chest,neck,waist,sleeve}
22	Banana Republic	9	Men	Tops	XXS	in	brand_standard	32.00	33.00	31.00	31.00	13.00	13.50	25.00	26.00	\N	\N	{chest,neck,waist,sleeve}
23	Banana Republic	9	Men	Tops	XS	in	brand_standard	34.00	35.00	32.00	32.00	13.00	13.50	27.00	28.00	\N	\N	{chest,neck,waist,sleeve}
24	Lululemon	1	Men	Tops	S	in	brand_standard	37.00	38.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
25	Lululemon	1	Men	Tops	M	in	brand_standard	39.00	40.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
26	Lululemon	1	Men	Tops	L	in	brand_standard	41.00	42.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
27	Lululemon	1	Men	Tops	XL	in	brand_standard	43.00	45.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
28	Lululemon	1	Men	Tops	XXL	in	brand_standard	46.00	48.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
29	Lululemon	1	Men	Tops	3XL	in	brand_standard	50.00	52.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
30	Lululemon	1	Men	Tops	4XL	in	brand_standard	53.00	55.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
31	Lululemon	1	Men	Tops	5XL	in	brand_standard	56.00	58.00	\N	\N	\N	\N	\N	\N	\N	\N	{chest}
32	Patagonia	2	Men	Tops	XXS	in	brand_standard	33.00	33.00	30.00	30.00	\N	\N	32.00	32.00	\N	\N	{chest,waist,sleeve}
33	Patagonia	2	Men	Tops	XS	in	brand_standard	35.00	35.00	32.00	32.00	\N	\N	34.00	34.00	\N	\N	{chest,waist,sleeve}
34	Patagonia	2	Men	Tops	S	in	brand_standard	37.00	37.00	33.00	33.00	\N	\N	36.00	36.00	\N	\N	{chest,waist,sleeve}
35	Patagonia	2	Men	Tops	M	in	brand_standard	40.00	40.00	34.00	34.00	\N	\N	39.00	39.00	\N	\N	{chest,waist,sleeve}
36	Patagonia	2	Men	Tops	L	in	brand_standard	44.00	44.00	35.00	35.00	\N	\N	43.00	43.00	\N	\N	{chest,waist,sleeve}
37	Patagonia	2	Men	Tops	XL	in	brand_standard	47.00	47.00	36.00	36.00	\N	\N	46.00	46.00	\N	\N	{chest,waist,sleeve}
38	Patagonia	2	Men	Tops	XXL	in	brand_standard	50.00	50.00	37.00	37.00	\N	\N	49.00	49.00	\N	\N	{chest,waist,sleeve}
39	Patagonia	2	Men	Tops	XXXL	in	brand_standard	56.00	56.00	37.50	37.50	\N	\N	55.00	55.00	\N	\N	{chest,waist,sleeve}
40	Banana Republic	9	Men	Tops	S	in	brand_standard	36.00	37.00	33.00	33.00	14.00	14.50	29.00	31.00	\N	\N	{chest,neck,waist,sleeve}
41	Banana Republic	9	Men	Tops	M	in	brand_standard	38.00	40.00	34.00	34.00	15.00	15.50	32.00	33.00	\N	\N	{chest,neck,waist,sleeve}
42	Banana Republic	9	Men	Tops	L	in	brand_standard	41.00	44.00	35.00	35.00	16.00	16.50	34.00	35.00	\N	\N	{chest,neck,waist,sleeve}
43	Banana Republic	9	Men	Tops	XL	in	brand_standard	45.00	48.00	35.50	35.50	17.00	17.50	36.00	37.00	\N	\N	{chest,neck,waist,sleeve}
44	Banana Republic	9	Men	Tops	XXL	in	brand_standard	49.00	52.00	36.00	36.00	18.00	18.50	38.00	39.00	\N	\N	{chest,neck,waist,sleeve}
45	Aritzia	11	Women	Undisc	2XS	in	brand_standard	30.50	30.50	\N	\N	\N	\N	22.50	22.50	\N	\N	{chest,waist}
46	Aritzia	11	Women	Undisc	XS	in	brand_standard	32.00	33.00	\N	\N	\N	\N	24.00	25.00	\N	\N	{chest,waist}
47	Aritzia	11	Women	Undisc	S	in	brand_standard	34.00	35.00	\N	\N	\N	\N	26.00	27.00	\N	\N	{chest,waist}
48	Aritzia	11	Women	Undisc	M	in	brand_standard	36.00	37.50	\N	\N	\N	\N	28.00	29.75	\N	\N	{chest,waist}
49	Aritzia	11	Women	Undisc	L	in	brand_standard	39.00	40.50	\N	\N	\N	\N	31.50	33.25	\N	\N	{chest,waist}
50	Aritzia	11	Women	Undisc	XL	in	brand_standard	42.00	43.50	\N	\N	\N	\N	35.00	36.75	\N	\N	{chest,waist}
51	Aritzia	11	Women	Undisc	XXL	in	brand_standard	45.00	45.00	\N	\N	\N	\N	38.50	38.50	\N	\N	{chest,waist}
52	Aritzia	11	Women	Undisc	00	in	brand_standard	30.50	30.50	\N	\N	\N	\N	22.50	22.50	\N	\N	{chest,waist}
53	Aritzia	11	Women	Undisc	0	in	brand_standard	32.00	32.00	\N	\N	\N	\N	24.00	24.00	\N	\N	{chest,waist}
54	Aritzia	11	Women	Undisc	2	in	brand_standard	33.00	33.00	\N	\N	\N	\N	25.00	25.00	\N	\N	{chest,waist}
55	Aritzia	11	Women	Undisc	4	in	brand_standard	34.00	34.00	\N	\N	\N	\N	26.00	26.00	\N	\N	{chest,waist}
56	Aritzia	11	Women	Undisc	6	in	brand_standard	35.00	35.00	\N	\N	\N	\N	27.00	27.00	\N	\N	{chest,waist}
57	Aritzia	11	Women	Undisc	8	in	brand_standard	36.00	36.00	\N	\N	\N	\N	28.00	28.00	\N	\N	{chest,waist}
58	Aritzia	11	Women	Undisc	10	in	brand_standard	37.50	37.50	\N	\N	\N	\N	29.75	29.75	\N	\N	{chest,waist}
59	Aritzia	11	Women	Undisc	12	in	brand_standard	39.00	39.00	\N	\N	\N	\N	31.50	31.50	\N	\N	{chest,waist}
60	Aritzia	11	Women	Undisc	14	in	brand_standard	40.50	40.50	\N	\N	\N	\N	33.25	33.25	\N	\N	{chest,waist}
61	Aritzia	11	Women	Undisc	16	in	brand_standard	42.00	42.00	\N	\N	\N	\N	35.00	35.00	\N	\N	{chest,waist}
\.


--
-- Data for Name: universal_categories; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.universal_categories (id, category) FROM stdin;
1	Tops
3	Jackets
4	Pants
12	Undisc
13	Dresses
\.


--
-- Data for Name: user_body_measurements; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.user_body_measurements (id, user_id, measurement_type, calculated_min, calculated_max, confidence_score, calculation_date, data_points) FROM stdin;
\.


--
-- Data for Name: user_fit_feedback; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.user_fit_feedback (id, user_id, garment_id, overall_fit, chest_fit, sleeve_fit, neck_fit, waist_fit, brand_id, brand_name, product_name, chest_code, shoulder_code, sleeve_code, length_code, neck_code, waist_code) FROM stdin;
6	1	3	Loose but I Like It	Loose but I Like It	Loose but I Like It	\N	Loose but I Like It	2	Patagonia	\N	5	\N	5	\N	\N	5
3	1	1	Good Fit	Good Fit	\N	\N	\N	1	Lululemon	Evolution Long-Sleeve Polo Shirt	1	\N	\N	\N	\N	\N
8	1	7	Tight but I Like It	Tight but I Like It	\N	\N	\N	\N	Theory	Brenan Polo Shirt in Cotton-Linen	3	\N	\N	\N	\N	\N
\.


--
-- Data for Name: user_fit_zones; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.user_fit_zones (id, user_id, category, tight_min, good_min, good_max, relaxed_max, tight_max, relaxed_min) FROM stdin;
1	1	Tops	35.89	38.315	40.685	48.41	37	47
\.


--
-- Data for Name: user_garment_inputs; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.user_garment_inputs (id, user_id, product_link, size_label, created_at, processed, brand_id, processing_error, measurements) FROM stdin;
4	1	https://bananarepublic.gap.com/browse/product.do?pid=666666	L	2025-02-22 00:57:10.008167	f	9	\N	{"neck_range": "16-16.5", "chest_range": "41-44", "waist_range": "34-35", "sleeve_range": "35"}
1	1	https://bananarepublic.gap.com/browse/product.do?pid=800139112	L	2025-02-22 00:53:45.552723	f	9	\N	{"neck_range": "16-16.5", "chest_range": "41-44", "waist_range": "34-35", "sleeve_range": "35"}
2	1	https://bananarepublic.gap.com/browse/product.do?pid=987654321	L	2025-02-22 00:55:35.90703	f	9	\N	{"neck_range": "16-16.5", "chest_range": "41-44", "waist_range": "34-35", "sleeve_range": "35"}
3	1	https://bananarepublic.gap.com/browse/product.do?pid=555555	XL	2025-02-22 00:56:28.705116	f	9	\N	{"neck_range": "17-17.5", "chest_range": "45-48", "waist_range": "36-37", "sleeve_range": "35.5"}
5	1	https://bananarepublic.gap.com/browse/product.do?pid=777777	M	2025-02-22 01:00:15.239772	f	9	\N	{"neck_range": "15-15.5", "chest_range": "38-40", "waist_range": "32-33", "sleeve_range": "34"}
7	1	https://bananarepublic.gap.com/browse/product.do?pid=777777	L	2025-02-22 01:00:57.140702	f	9	\N	{"neck_range": "16-16.5", "chest_range": "41-44", "waist_range": "34-35", "sleeve_range": "35"}
8	1	https://bananarepublic.gap.com/browse/product.do?pid=888888	XL	2025-02-22 01:01:54.011987	f	9	\N	{"neck_range": "17-17.5", "chest_range": "45-48", "waist_range": "36-37", "sleeve_range": "35.5"}
\.


--
-- Data for Name: user_garments; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.user_garments (id, user_id, brand_id, category, size_label, chest_range, fit_feedback, created_at, owns_garment, product_name, product_link, brand_name) FROM stdin;
30	1	9	Tops	L	41-44	\N	2025-02-22 01:13:34.380441	t	Soft Wash Long-Sleeve T-Shirt	https://bananarepublic.gap.com/browse/product.do?pid=800139112&vid=1#pdp-page-content	Banana Republic
3	1	2	Tops	XL	47	Loose but I Like It	2025-02-18 00:22:32.857724	t	\N	\N	Patagonia
1	1	1	Tops	M	39-40	Good Fit	2025-02-17 23:52:16.031871	t	Evolution Long-Sleeve Polo Shirt	https://shop.lululemon.com/p/men-ls-tops/Evolution-Long-Sleeve-Polo-Shirt/_/prod11560102	Lululemon
7	1	3	Tops	S	36.0-38.0	Tight but I Like It	2025-02-19 21:59:07.412855	t	Brenan Polo Shirt in Cotton-Linen	https://www.theory.com/brenan-polo-shirt-in-cotton-linen/N0483701_100.html?srsltid=AfmBOorU6vBdqHVjt7Dm87fupTgKAaeZAyvPEpWDnAoMrP7kiEx3BOON	Theory
\.


--
-- Data for Name: user_garments_v2; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.user_garments_v2 (id, user_id, brand_id, brand_name, category, size_label, product_name, product_link, owns_garment, created_at, overall_code, chest_code, shoulder_code, sleeve_code, length_code, neck_code, waist_code, hip_code, inseam_code, chest_min, chest_max) FROM stdin;
30	1	9	Banana Republic	Tops	L	Soft Wash Long-Sleeve T-Shirt	https://bananarepublic.gap.com/browse/product.do?pid=800139112&vid=1#pdp-page-content	t	2025-02-22 01:13:34.380441	\N	\N	\N	\N	\N	\N	\N	\N	\N	41.0	44.0
3	1	2	Patagonia	Tops	XL	\N	\N	t	2025-02-18 00:22:32.857724	5	5	\N	5	\N	\N	5	\N	\N	47.0	47.0
1	1	1	Lululemon	Tops	M	Evolution Long-Sleeve Polo Shirt	https://shop.lululemon.com/p/men-ls-tops/Evolution-Long-Sleeve-Polo-Shirt/_/prod11560102	t	2025-02-17 23:52:16.031871	1	1	\N	\N	\N	\N	\N	\N	\N	39.0	40.0
7	1	3	Theory	Tops	S	Brenan Polo Shirt in Cotton-Linen	https://www.theory.com/brenan-polo-shirt-in-cotton-linen/N0483701_100.html?srsltid=AfmBOorU6vBdqHVjt7Dm87fupTgKAaeZAyvPEpWDnAoMrP7kiEx3BOON	t	2025-02-19 21:59:07.412855	3	3	\N	\N	\N	\N	\N	\N	\N	36.0	38.0
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.users (id, created_at, email, gender, unit_preference, test_column) FROM stdin;
1	2025-02-17 23:48:08.770592	testuser@example.com	Men	in	\N
\.


--
-- Data for Name: women_sizeguides; Type: TABLE DATA; Schema: public; Owner: tailor2_admin
--

COPY public.women_sizeguides (id, brand, brand_id, category, size_label, unit, data_quality, bust_min, bust_max, waist_min, waist_max, hip_min, hip_max, measurements_available) FROM stdin;
1	Aritzia	11	Undisc	2XS	in	brand_standard	30.5	30.5	22.5	22.5	\N	\N	{bust,waist}
2	Aritzia	11	Undisc	XS	in	brand_standard	32.0	33.0	24.0	25.0	\N	\N	{bust,waist}
3	Aritzia	11	Undisc	S	in	brand_standard	34.0	35.0	26.0	27.0	\N	\N	{bust,waist}
4	Aritzia	11	Undisc	M	in	brand_standard	36.0	37.5	28.0	29.8	\N	\N	{bust,waist}
5	Aritzia	11	Undisc	L	in	brand_standard	39.0	40.5	31.5	33.3	\N	\N	{bust,waist}
6	Aritzia	11	Undisc	XL	in	brand_standard	42.0	43.5	35.0	36.8	\N	\N	{bust,waist}
7	Aritzia	11	Undisc	XXL	in	brand_standard	45.0	45.0	38.5	38.5	\N	\N	{bust,waist}
8	Aritzia	11	Undisc	00	in	brand_standard	30.5	30.5	22.5	22.5	\N	\N	{bust,waist}
9	Aritzia	11	Undisc	0	in	brand_standard	32.0	32.0	24.0	24.0	\N	\N	{bust,waist}
10	Aritzia	11	Undisc	2	in	brand_standard	33.0	33.0	25.0	25.0	\N	\N	{bust,waist}
11	Aritzia	11	Undisc	4	in	brand_standard	34.0	34.0	26.0	26.0	\N	\N	{bust,waist}
12	Aritzia	11	Undisc	6	in	brand_standard	35.0	35.0	27.0	27.0	\N	\N	{bust,waist}
13	Aritzia	11	Undisc	8	in	brand_standard	36.0	36.0	28.0	28.0	\N	\N	{bust,waist}
14	Aritzia	11	Undisc	10	in	brand_standard	37.5	37.5	29.8	29.8	\N	\N	{bust,waist}
15	Aritzia	11	Undisc	12	in	brand_standard	39.0	39.0	31.5	31.5	\N	\N	{bust,waist}
16	Aritzia	11	Undisc	14	in	brand_standard	40.5	40.5	33.3	33.3	\N	\N	{bust,waist}
17	Aritzia	11	Undisc	16	in	brand_standard	42.0	42.0	35.0	35.0	\N	\N	{bust,waist}
\.


--
-- Data for Name: automated_imports; Type: TABLE DATA; Schema: raw_size_guides; Owner: tailor2_admin
--

COPY raw_size_guides.automated_imports (id, brand_name, product_type, department, category, measurements, unit_system, image_path, ocr_confidence, status, review_notes, reviewed_by, reviewed_at, created_at, processed_at, metadata, brand_id) FROM stdin;
\.


--
-- Name: automap_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.automap_id_seq', 4, true);


--
-- Name: brand_automap_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.brand_automap_id_seq', 9, true);


--
-- Name: brands_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.brands_id_seq', 12, true);


--
-- Name: database_metadata_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.database_metadata_id_seq', 4, true);


--
-- Name: dress_category_mapping_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.dress_category_mapping_id_seq', 9, true);


--
-- Name: dress_product_override_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.dress_product_override_id_seq', 1, true);


--
-- Name: dress_size_guide_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.dress_size_guide_id_seq', 92, true);


--
-- Name: measurement_confidence_factors_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.measurement_confidence_factors_id_seq', 4, true);


--
-- Name: men_sizeguides_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.men_sizeguides_id_seq', 44, true);


--
-- Name: processing_logs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.processing_logs_id_seq', 13, true);


--
-- Name: product_measurements_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.product_measurements_id_seq', 1, true);


--
-- Name: size_guide_mappings_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.size_guide_mappings_id_seq', 9, true);


--
-- Name: size_guide_sources_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.size_guide_sources_id_seq', 8, true);


--
-- Name: size_guides_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.size_guides_id_seq', 73, true);


--
-- Name: size_guides_v2_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.size_guides_v2_id_seq', 61, true);


--
-- Name: universal_categories_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.universal_categories_id_seq', 13, true);


--
-- Name: user_body_measurements_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.user_body_measurements_id_seq', 1, false);


--
-- Name: user_fit_feedback_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.user_fit_feedback_id_seq', 8, true);


--
-- Name: user_fit_zones_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.user_fit_zones_id_seq', 175, true);


--
-- Name: user_garment_inputs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.user_garment_inputs_id_seq', 8, true);


--
-- Name: user_garments_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.user_garments_id_seq', 38, true);


--
-- Name: user_garments_v2_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.user_garments_v2_id_seq', 1, false);


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.users_id_seq', 1, true);


--
-- Name: women_sizeguides_id_seq; Type: SEQUENCE SET; Schema: public; Owner: tailor2_admin
--

SELECT pg_catalog.setval('public.women_sizeguides_id_seq', 17, true);


--
-- Name: automated_imports_id_seq; Type: SEQUENCE SET; Schema: raw_size_guides; Owner: tailor2_admin
--

SELECT pg_catalog.setval('raw_size_guides.automated_imports_id_seq', 1, false);


--
-- Name: automap automap_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.automap
    ADD CONSTRAINT automap_pkey PRIMARY KEY (id);


--
-- Name: automap automap_raw_term_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.automap
    ADD CONSTRAINT automap_raw_term_key UNIQUE (raw_term);


--
-- Name: brand_automap brand_automap_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.brand_automap
    ADD CONSTRAINT brand_automap_pkey PRIMARY KEY (id);


--
-- Name: brands brands_name_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_name_key UNIQUE (name);


--
-- Name: brands brands_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_pkey PRIMARY KEY (id);


--
-- Name: database_metadata database_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.database_metadata
    ADD CONSTRAINT database_metadata_pkey PRIMARY KEY (id);


--
-- Name: database_metadata database_metadata_table_name_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.database_metadata
    ADD CONSTRAINT database_metadata_table_name_key UNIQUE (table_name);


--
-- Name: dress_category_mapping dress_category_mapping_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_category_mapping
    ADD CONSTRAINT dress_category_mapping_pkey PRIMARY KEY (id);


--
-- Name: dress_product_override dress_product_override_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_product_override
    ADD CONSTRAINT dress_product_override_pkey PRIMARY KEY (id);


--
-- Name: dress_size_guide dress_size_guide_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_size_guide
    ADD CONSTRAINT dress_size_guide_pkey PRIMARY KEY (id);


--
-- Name: feedback_codes feedback_codes_feedback_text_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.feedback_codes
    ADD CONSTRAINT feedback_codes_feedback_text_key UNIQUE (feedback_text);


--
-- Name: feedback_codes feedback_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.feedback_codes
    ADD CONSTRAINT feedback_codes_pkey PRIMARY KEY (code);


--
-- Name: measurement_confidence_factors measurement_confidence_factors_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.measurement_confidence_factors
    ADD CONSTRAINT measurement_confidence_factors_pkey PRIMARY KEY (id);


--
-- Name: men_sizeguides men_sizeguides_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.men_sizeguides
    ADD CONSTRAINT men_sizeguides_pkey PRIMARY KEY (id);


--
-- Name: processing_logs processing_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.processing_logs
    ADD CONSTRAINT processing_logs_pkey PRIMARY KEY (id);


--
-- Name: product_measurements product_measurements_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.product_measurements
    ADD CONSTRAINT product_measurements_pkey PRIMARY KEY (id);


--
-- Name: product_measurements product_measurements_product_code_size_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.product_measurements
    ADD CONSTRAINT product_measurements_product_code_size_key UNIQUE (product_code, size);


--
-- Name: size_guide_mappings size_guide_mappings_brand_size_guide_reference_universal_ca_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_mappings
    ADD CONSTRAINT size_guide_mappings_brand_size_guide_reference_universal_ca_key UNIQUE (brand, size_guide_reference, universal_category);


--
-- Name: size_guide_mappings size_guide_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_mappings
    ADD CONSTRAINT size_guide_mappings_pkey PRIMARY KEY (id);


--
-- Name: size_guide_mappings size_guide_mappings_unique; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_mappings
    ADD CONSTRAINT size_guide_mappings_unique UNIQUE (brand, size_guide_reference);


--
-- Name: size_guide_sources size_guide_sources_brand_category_source_url_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_sources
    ADD CONSTRAINT size_guide_sources_brand_category_source_url_key UNIQUE (brand, category, source_url);


--
-- Name: size_guide_sources size_guide_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_sources
    ADD CONSTRAINT size_guide_sources_pkey PRIMARY KEY (id);


--
-- Name: size_guides size_guides_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guides
    ADD CONSTRAINT size_guides_pkey PRIMARY KEY (id);


--
-- Name: size_guides_v2 size_guides_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guides_v2
    ADD CONSTRAINT size_guides_v2_pkey PRIMARY KEY (id);


--
-- Name: brand_automap unique_brand_term_mapping; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.brand_automap
    ADD CONSTRAINT unique_brand_term_mapping UNIQUE (brand_id, raw_term);


--
-- Name: size_guides unique_size_guide; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guides
    ADD CONSTRAINT unique_size_guide UNIQUE (brand, gender, category, size_label);


--
-- Name: user_fit_zones unique_user_category; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_zones
    ADD CONSTRAINT unique_user_category UNIQUE (user_id, category);


--
-- Name: user_fit_feedback unique_user_garment_feedback; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT unique_user_garment_feedback UNIQUE (user_id, garment_id);


--
-- Name: user_body_measurements unique_user_measurement; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_body_measurements
    ADD CONSTRAINT unique_user_measurement UNIQUE (user_id, measurement_type);


--
-- Name: universal_categories universal_categories_category_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.universal_categories
    ADD CONSTRAINT universal_categories_category_key UNIQUE (category);


--
-- Name: universal_categories universal_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.universal_categories
    ADD CONSTRAINT universal_categories_pkey PRIMARY KEY (id);


--
-- Name: user_body_measurements user_body_measurements_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_body_measurements
    ADD CONSTRAINT user_body_measurements_pkey PRIMARY KEY (id);


--
-- Name: user_fit_feedback user_fit_feedback_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_pkey PRIMARY KEY (id);


--
-- Name: user_fit_zones user_fit_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_zones
    ADD CONSTRAINT user_fit_zones_pkey PRIMARY KEY (id);


--
-- Name: user_garment_inputs user_garment_inputs_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garment_inputs
    ADD CONSTRAINT user_garment_inputs_pkey PRIMARY KEY (id);


--
-- Name: user_garment_inputs user_garment_inputs_user_id_product_link_size_label_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garment_inputs
    ADD CONSTRAINT user_garment_inputs_user_id_product_link_size_label_key UNIQUE (user_id, product_link, size_label);


--
-- Name: user_garments user_garments_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments
    ADD CONSTRAINT user_garments_pkey PRIMARY KEY (id);


--
-- Name: user_garments_v2 user_garments_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT user_garments_v2_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: women_sizeguides women_sizeguides_pkey; Type: CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.women_sizeguides
    ADD CONSTRAINT women_sizeguides_pkey PRIMARY KEY (id);


--
-- Name: automated_imports automated_imports_pkey; Type: CONSTRAINT; Schema: raw_size_guides; Owner: tailor2_admin
--

ALTER TABLE ONLY raw_size_guides.automated_imports
    ADD CONSTRAINT automated_imports_pkey PRIMARY KEY (id);


--
-- Name: user_garment_inputs_user_id_idx; Type: INDEX; Schema: public; Owner: tailor2_admin
--

CREATE INDEX user_garment_inputs_user_id_idx ON public.user_garment_inputs USING btree (user_id);


--
-- Name: user_garment_inputs garment_input_trigger; Type: TRIGGER; Schema: public; Owner: tailor2_admin
--

CREATE TRIGGER garment_input_trigger AFTER INSERT ON public.user_garment_inputs FOR EACH ROW EXECUTE FUNCTION public.log_garment_processing();


--
-- Name: user_fit_feedback update_fit_zones; Type: TRIGGER; Schema: public; Owner: tailor2_admin
--

CREATE TRIGGER update_fit_zones AFTER INSERT OR UPDATE ON public.user_fit_feedback FOR EACH ROW EXECUTE FUNCTION public.recalculate_fit_zones();


--
-- Name: user_fit_feedback update_garment_fit_feedback; Type: TRIGGER; Schema: public; Owner: tailor2_admin
--

CREATE TRIGGER update_garment_fit_feedback AFTER INSERT OR UPDATE ON public.user_fit_feedback FOR EACH ROW EXECUTE FUNCTION public.sync_fit_feedback();


--
-- Name: brand_automap brand_automap_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.brand_automap
    ADD CONSTRAINT brand_automap_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: dress_category_mapping dress_category_mapping_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_category_mapping
    ADD CONSTRAINT dress_category_mapping_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: dress_product_override dress_product_override_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_product_override
    ADD CONSTRAINT dress_product_override_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: dress_size_guide dress_size_guide_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.dress_size_guide
    ADD CONSTRAINT dress_size_guide_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: processing_logs processing_logs_input_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.processing_logs
    ADD CONSTRAINT processing_logs_input_id_fkey FOREIGN KEY (input_id) REFERENCES public.user_garment_inputs(id);


--
-- Name: product_measurements product_measurements_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.product_measurements
    ADD CONSTRAINT product_measurements_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: size_guide_mappings size_guide_mappings_universal_category_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_mappings
    ADD CONSTRAINT size_guide_mappings_universal_category_fkey FOREIGN KEY (universal_category) REFERENCES public.universal_categories(category);


--
-- Name: size_guide_sources size_guide_sources_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guide_sources
    ADD CONSTRAINT size_guide_sources_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: size_guides size_guides_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.size_guides
    ADD CONSTRAINT size_guides_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: user_body_measurements user_body_measurements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_body_measurements
    ADD CONSTRAINT user_body_measurements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_fit_feedback user_fit_feedback_chest_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_chest_code_fkey FOREIGN KEY (chest_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_garment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_garment_id_fkey FOREIGN KEY (garment_id) REFERENCES public.user_garments(id);


--
-- Name: user_fit_feedback user_fit_feedback_length_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_length_code_fkey FOREIGN KEY (length_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_neck_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_neck_code_fkey FOREIGN KEY (neck_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_shoulder_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_shoulder_code_fkey FOREIGN KEY (shoulder_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_sleeve_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_sleeve_code_fkey FOREIGN KEY (sleeve_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_feedback user_fit_feedback_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_fit_feedback user_fit_feedback_waist_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_feedback
    ADD CONSTRAINT user_fit_feedback_waist_code_fkey FOREIGN KEY (waist_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_fit_zones user_fit_zones_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_fit_zones
    ADD CONSTRAINT user_fit_zones_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_garment_inputs user_garment_inputs_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garment_inputs
    ADD CONSTRAINT user_garment_inputs_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: user_garment_inputs user_garment_inputs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garment_inputs
    ADD CONSTRAINT user_garment_inputs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_garments user_garments_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments
    ADD CONSTRAINT user_garments_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: user_garments user_garments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments
    ADD CONSTRAINT user_garments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_garments_v2 valid_chest_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_chest_code FOREIGN KEY (chest_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_hip_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_hip_code FOREIGN KEY (hip_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_inseam_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_inseam_code FOREIGN KEY (inseam_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_length_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_length_code FOREIGN KEY (length_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_neck_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_neck_code FOREIGN KEY (neck_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_overall_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_overall_code FOREIGN KEY (overall_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_shoulder_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_shoulder_code FOREIGN KEY (shoulder_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_sleeve_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_sleeve_code FOREIGN KEY (sleeve_code) REFERENCES public.feedback_codes(code);


--
-- Name: user_garments_v2 valid_waist_code; Type: FK CONSTRAINT; Schema: public; Owner: tailor2_admin
--

ALTER TABLE ONLY public.user_garments_v2
    ADD CONSTRAINT valid_waist_code FOREIGN KEY (waist_code) REFERENCES public.feedback_codes(code);


--
-- Name: automated_imports automated_imports_brand_id_fkey; Type: FK CONSTRAINT; Schema: raw_size_guides; Owner: tailor2_admin
--

ALTER TABLE ONLY raw_size_guides.automated_imports
    ADD CONSTRAINT automated_imports_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: automated_imports automated_imports_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: raw_size_guides; Owner: tailor2_admin
--

ALTER TABLE ONLY raw_size_guides.automated_imports
    ADD CONSTRAINT automated_imports_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);


--
-- Name: trigger_refresh_metadata; Type: EVENT TRIGGER; Schema: -; Owner: tailor2_admin
--

CREATE EVENT TRIGGER trigger_refresh_metadata ON ddl_command_end
         WHEN TAG IN ('ALTER TABLE')
   EXECUTE FUNCTION public.refresh_metadata_on_alter_table();


ALTER EVENT TRIGGER trigger_refresh_metadata OWNER TO tailor2_admin;

--
-- PostgreSQL database dump complete
--

