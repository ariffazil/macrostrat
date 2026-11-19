/*
 * 0004-macrostrat_epistemic.sql — Epistemic Metadata Extension
 *
 * Adds provenance, confidence, and uncertainty metadata to Macrostrat
 * geological data without modifying any existing tables.
 *
 * WHAT THIS EXTENSION PROVIDES:
 *   macrostrat_epistemic.classifications      — epistemic level per entity
 *   macrostrat_epistemic.uncertainty_bounds   — P10/P50/P90 per numeric field
 *   macrostrat_epistemic.timescale_revisions  — versioned shift tracking
 *
 * WHY:
 *   Macrostrat stores authoritative geological data, but every unit,
 *   lithology, age assignment, and column is stored with equal authority.
 *   There is no way to distinguish between:
 *     - OBSERVED: directly measured (e.g., Brunhes normal subchron from
 *       astronomically tuned GPTS — ±0.5% age uncertainty)
 *     - DERIVED: computed from well-understood physics
 *     - INTERPRETED: inferred from proxy data with intermediate assumptions
 *     - SPECULATION: plausible but unconstrained (analogy, statistical)
 *     - UNKNOWN: cannot be known in principle
 *
 *   This extension also addresses Issue #261 (the ambiguity between
 *   NULL and 0 for thickness values) by providing explicit P10/P50/P90
 *   uncertainty bounds on any numeric field.
 *
 * DESIGN PRINCIPLES:
 *   - PURELY ADDITIVE: No ALTER on existing tables. No data migration.
 *   - COMPOSABLE: Multiple epistemic tags can coexist.
 *   - SUPERSEDEABLE: Later classifications supersede earlier ones.
 *   - ATTRIBUTABLE: Every classification records who/what classified it.
 *
 * LICENSE: Apache 2.0 (same as Macrostrat)
 * AUTHOR:  Muhammad Arif bin Fazil / arifOS GEOX organ
 *          Based on epistemic classification system from
 *          GEOX constitutional floors F2 TRUTH, F7 HUMILITY,
 *          F9 ANTI-HANTU (https://github.com/ariffazil/geox)
 *
 * DITEMPA BUKAN DIBERI — Forged, Not Given
 */

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

-- ============================================================================
-- SCHEMA
-- ============================================================================

CREATE SCHEMA macrostrat_epistemic;
ALTER SCHEMA macrostrat_epistemic OWNER TO macrostrat_admin;
SET default_tablespace = '';
SET default_table_access_method = heap;

-- ============================================================================
-- ENUM TYPES
-- ============================================================================

CREATE TYPE macrostrat_epistemic.epistemic_level AS ENUM (
    'OBSERVED',       -- Direct measurement (core, outcrop, well log)
    'DERIVED',        -- Computed from well-understood physics (Archie, Gardner)
    'INTERPRETED',    -- Inferred from proxy data with intermediate assumptions
    'SPECULATION',    -- Plausible but unconstrained (analogy, statistical)
    'UNKNOWN',        -- Cannot be known in principle (F9 ANTI-HANTU guard)
    'NO_DATA'         -- Data exists but not yet ingested into this system
);
ALTER TYPE macrostrat_epistemic.epistemic_level OWNER TO macrostrat_admin;

CREATE TYPE macrostrat_epistemic.quality_assertion AS ENUM (
    'verified',       -- Independently confirmed by multiple sources
    'plausible',      -- Consistent with available evidence
    'ambiguous',      -- Could be interpreted in multiple ways
    'contested',      -- Multiple sources disagree
    'erroneous',      -- Known to be incorrect
    'unassessed'      -- Not yet reviewed (default for new entries)
);
ALTER TYPE macrostrat_epistemic.quality_assertion OWNER TO macrostrat_admin;

CREATE TYPE macrostrat_epistemic.uncertainty_distribution AS ENUM (
    'normal',
    'lognormal',
    'triangular',
    'uniform',
    'expert_elicit',
    'unknown'
);
ALTER TYPE macrostrat_epistemic.uncertainty_distribution OWNER TO macrostrat_admin;

-- ============================================================================
-- TABLE: macrostrat_epistemic.classifications
-- ============================================================================

CREATE TABLE macrostrat_epistemic.classifications (
    id integer NOT NULL,
    table_name text NOT NULL,
    row_id integer NOT NULL,
    epistemic_level macrostrat_epistemic.epistemic_level NOT NULL,
    confidence numeric(3,2),
    quality macrostrat_epistemic.quality_assertion DEFAULT 'unassessed' NOT NULL,
    classifier_type text,
    classifier_id text,
    source_citation text,
    notes text,
    superseded_by integer,
    date_created timestamp with time zone DEFAULT now() NOT NULL,
    date_modified timestamp with time zone
);
ALTER TABLE macrostrat_epistemic.classifications OWNER TO macrostrat_admin;

COMMENT ON TABLE macrostrat_epistemic.classifications IS
    'Epistemic classification for any entity in the Macrostrat database. ' ||
    'Attaches an epistemic level (OBSERVED/DERIVED/INTERPRETED/SPECULATION/UNKNOWN) ' ||
    'and confidence score to rows in units, cols, liths, intervals, or any other table.';

COMMENT ON COLUMN macrostrat_epistemic.classifications.table_name IS
    'Name of the table containing the classified entity (e.g. "units", "cols", "intervals")';
COMMENT ON COLUMN macrostrat_epistemic.classifications.row_id IS
    'Primary key value of the classified entity in the referenced table';
COMMENT ON COLUMN macrostrat_epistemic.classifications.epistemic_level IS
    'OBSERVED: direct measurement. DERIVED: physics-based computation. ' ||
    'INTERPRETED: proxy with assumptions. SPECULATION: unconstrained analogy. ' ||
    'UNKNOWN: cannot be known. NO_DATA: exists but not ingested.';
COMMENT ON COLUMN macrostrat_epistemic.classifications.confidence IS
    'Confidence score 0.00-0.99. Constitutionally capped at 0.90 per F7 HUMILITY.';
COMMENT ON COLUMN macrostrat_epistemic.classifications.classifier_type IS
    'Who or what produced this classification: human, model, automated, peer_review';
COMMENT ON COLUMN macrostrat_epistemic.classifications.superseded_by IS
    'If set, this classification has been superseded by another. NULL = active.';

CREATE SEQUENCE macrostrat_epistemic.classifications_id_seq
    AS integer START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE macrostrat_epistemic.classifications_id_seq OWNER TO macrostrat_admin;
ALTER SEQUENCE macrostrat_epistemic.classifications_id_seq OWNED BY macrostrat_epistemic.classifications.id;

ALTER TABLE ONLY macrostrat_epistemic.classifications
    ALTER COLUMN id SET DEFAULT nextval('macrostrat_epistemic.classifications_id_seq'::regclass);

CREATE UNIQUE INDEX ix_classifications_active
    ON macrostrat_epistemic.classifications (table_name, row_id, classifier_id)
    WHERE superseded_by IS NULL;

CREATE INDEX ix_classifications_entity
    ON macrostrat_epistemic.classifications (table_name, row_id);

-- ============================================================================
-- TABLE: macrostrat_epistemic.uncertainty_bounds
-- ============================================================================

CREATE TABLE macrostrat_epistemic.uncertainty_bounds (
    id integer NOT NULL,
    table_name text NOT NULL,
    row_id integer NOT NULL,
    column_name text NOT NULL,
    p10 numeric NOT NULL,
    p50 numeric NOT NULL,
    p90 numeric NOT NULL,
    distribution macrostrat_epistemic.uncertainty_distribution DEFAULT 'unknown' NOT NULL,
    method text,
    notes text,
    date_created timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE macrostrat_epistemic.uncertainty_bounds OWNER TO macrostrat_admin;

COMMENT ON TABLE macrostrat_epistemic.uncertainty_bounds IS
    'P10/P50/P90 uncertainty distributions for numeric columns on any table. ' ||
    'Addresses Issue #261 (NULL vs 0 ambiguity) by allowing explicit uncertainty ' ||
    'ranges on thickness, age, and position values.';

COMMENT ON COLUMN macrostrat_epistemic.uncertainty_bounds.column_name IS
    'The specific numeric column being bounded (e.g. max_thick, min_thick, t_age, b_age)';
COMMENT ON COLUMN macrostrat_epistemic.uncertainty_bounds.p10 IS
    '10th percentile value. For thickness: P10 = thin (conservative). For age: P10 = old.';
COMMENT ON COLUMN macrostrat_epistemic.uncertainty_bounds.p50 IS
    'Median value. Best single estimate.';
COMMENT ON COLUMN macrostrat_epistemic.uncertainty_bounds.p90 IS
    '90th percentile value. For thickness: P90 = thick. For age: P90 = young.';

CREATE SEQUENCE macrostrat_epistemic.uncertainty_bounds_id_seq
    AS integer START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE macrostrat_epistemic.uncertainty_bounds_id_seq OWNER TO macrostrat_admin;
ALTER SEQUENCE macrostrat_epistemic.uncertainty_bounds_id_seq OWNED BY macrostrat_epistemic.uncertainty_bounds.id;

ALTER TABLE ONLY macrostrat_epistemic.uncertainty_bounds
    ALTER COLUMN id SET DEFAULT nextval('macrostrat_epistemic.uncertainty_bounds_id_seq'::regclass);

CREATE UNIQUE INDEX ix_uncertainty_bounds_unique
    ON macrostrat_epistemic.uncertainty_bounds (table_name, row_id, column_name);

CREATE INDEX ix_uncertainty_bounds_entity
    ON macrostrat_epistemic.uncertainty_bounds (table_name, row_id);

-- ============================================================================
-- TABLE: macrostrat_epistemic.timescale_revisions
-- ============================================================================

CREATE TABLE macrostrat_epistemic.timescale_revisions (
    id integer NOT NULL,
    interval_id integer NOT NULL,
    previous_name text,
    previous_t_age numeric(8,4),
    previous_b_age numeric(8,4),
    new_t_age numeric(8,4),
    new_b_age numeric(8,4),
    timescale_version text NOT NULL,
    boundary_change_type text,
    affected_units integer DEFAULT 0,
    affected_columns integer DEFAULT 0,
    status text DEFAULT 'pending' NOT NULL,
    notes text,
    applied_by text,
    applied_at timestamp with time zone,
    date_created timestamp with time zone DEFAULT now() NOT NULL,

    CONSTRAINT fk_timescale_revisions_interval
        FOREIGN KEY (interval_id)
        REFERENCES macrostrat.intervals(id)
        ON DELETE RESTRICT
);
ALTER TABLE macrostrat_epistemic.timescale_revisions OWNER TO macrostrat_admin;

COMMENT ON TABLE macrostrat_epistemic.timescale_revisions IS
    'Versioned record of time scale interval boundary changes across revisions. ' ||
    'Tracks what changed, why, and how many downstream records are affected.';

COMMENT ON COLUMN macrostrat_epistemic.timescale_revisions.boundary_change_type IS
    'Classification of how the boundary changed: shifted_younger, shifted_older, split, merged, unchanged';
COMMENT ON COLUMN macrostrat_epistemic.timescale_revisions.affected_units IS
    'Number of rows in macrostrat.units whose fo or lo references this interval.';
COMMENT ON COLUMN macrostrat_epistemic.timescale_revisions.status IS
    'pending = not yet reviewed. previewed = impact calculated. ' ||
    'applied = revision accepted. rejected = revision declined.';

CREATE SEQUENCE macrostrat_epistemic.timescale_revisions_id_seq
    AS integer START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE macrostrat_epistemic.timescale_revisions_id_seq OWNER TO macrostrat_admin;
ALTER SEQUENCE macrostrat_epistemic.timescale_revisions_id_seq OWNED BY macrostrat_epistemic.timescale_revisions.id;

ALTER TABLE ONLY macrostrat_epistemic.timescale_revisions
    ALTER COLUMN id SET DEFAULT nextval('macrostrat_epistemic.timescale_revisions_id_seq'::regclass);

CREATE INDEX ix_timescale_revisions_interval
    ON macrostrat_epistemic.timescale_revisions (interval_id);

CREATE INDEX ix_timescale_revisions_status
    ON macrostrat_epistemic.timescale_revisions (status);

-- ============================================================================
-- VIEW: macrostrat_epistemic.classification_summary
-- ============================================================================

CREATE VIEW macrostrat_epistemic.classification_summary AS
    SELECT DISTINCT ON (c.table_name, c.row_id)
        c.id,
        c.table_name,
        c.row_id,
        c.epistemic_level,
        c.confidence,
        c.quality,
        c.classifier_type,
        c.classifier_id,
        c.source_citation,
        c.notes,
        c.date_created
    FROM macrostrat_epistemic.classifications c
    WHERE c.superseded_by IS NULL
    ORDER BY c.table_name, c.row_id, c.date_created DESC;
ALTER VIEW macrostrat_epistemic.classification_summary OWNER TO macrostrat_admin;

-- ============================================================================
-- FUNCTION: macrostrat_epistemic.compute_timescale_impact
-- ============================================================================

CREATE FUNCTION macrostrat_epistemic.compute_timescale_impact(
    p_interval_id integer,
    p_new_t_age numeric,
    p_new_b_age numeric
) RETURNS TABLE (
    interval_name text,
    old_t_age numeric,
    old_b_age numeric,
    new_t_age numeric,
    new_b_age numeric,
    age_shift_younger numeric,
    affected_units_count bigint,
    affected_columns_count bigint
) LANGUAGE sql STABLE AS $$
    SELECT
        i.name::text,
        i.t_age,
        i.b_age,
        p_new_t_age,
        p_new_b_age,
        abs(i.t_age - p_new_t_age) + abs(i.b_age - p_new_b_age) AS age_shift_younger,
        (SELECT count(*) FROM macrostrat.units u WHERE u.fo = p_interval_id OR u.lo = p_interval_id)::bigint,
        (SELECT count(DISTINCT u.col_id) FROM macrostrat.units u WHERE u.fo = p_interval_id OR u.lo = p_interval_id)::bigint
    FROM macrostrat.intervals i
    WHERE i.id = p_interval_id;
$$;
ALTER FUNCTION macrostrat_epistemic.compute_timescale_impact(integer, numeric, numeric) OWNER TO macrostrat_admin;

-- ============================================================================
-- PERMISSIONS
-- ============================================================================

GRANT SELECT ON ALL TABLES IN SCHEMA macrostrat_epistemic TO web_user;
GRANT SELECT ON ALL TABLES IN SCHEMA macrostrat_epistemic TO web_anon;
GRANT SELECT, USAGE ON ALL SEQUENCES IN SCHEMA macrostrat_epistemic TO web_user;
GRANT INSERT, UPDATE ON TABLE macrostrat_epistemic.classifications TO web_user;
GRANT INSERT, UPDATE ON TABLE macrostrat_epistemic.uncertainty_bounds TO web_user;
GRANT INSERT, UPDATE ON TABLE macrostrat_epistemic.timescale_revisions TO web_user;

ALTER DEFAULT PRIVILEGES FOR ROLE macrostrat_admin IN SCHEMA macrostrat_epistemic
    GRANT SELECT, USAGE ON SEQUENCES TO web_user;
ALTER DEFAULT PRIVILEGES FOR ROLE macrostrat_admin IN SCHEMA macrostrat_epistemic
    GRANT SELECT ON TABLES TO web_anon;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON SCHEMA macrostrat_epistemic IS
    'Epistemic Metadata Extension for Macrostrat. ' ||
    'Adds confidence, provenance, and uncertainty metadata to geological data. ' ||
    'Purely additive — no existing tables are modified. ' ||
    'Based on constitutional floors F2 TRUTH, F7 HUMILITY, F9 ANTI-HANTU ' ||
    'from arifOS GEOX (https://github.com/ariffazil/geox). ' ||
    'DITEMPA BUKAN DIBERI — Forged, Not Given.';
