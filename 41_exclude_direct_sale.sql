-- ----------------------------------------------------------------------------
-- 41_exclude_direct_sale.sql
-- Adds a "Fleet only (exclude Direct Sale)" filter to the dashboard device charts/KPIs.
-- Direct Sale = ie_eeros.organization ILIKE '%direct%' (today the only two org values are
-- 'Cable One' and 'Direct Sale'; the substring matches the app's isDirectSale() /direct/i).
--
-- Adds `p_exclude_direct_sale boolean default false` to get_dashboard_stats, get_transition_mix,
-- get_device_mix_history, get_weekly_model_adds (signature changes -> DROP + CREATE; the param
-- defaults false so existing 2/3-arg PostgREST calls keep working).
--
-- Device Mix Over Time reads the pre-aggregate ie_eeros_model_daily, which had no org column.
-- We add one and group refresh_eero_aggregates by it. NOTE: ie_eeros is retained latest-only
-- (apply_retention Class A), so this fills org FORWARD only — historical model_daily rows keep
-- organization = NULL and are KEPT (treated as fleet) by the device-mix filter.
--
-- Apply as `vantage` on `eero_vantage`. Idempotent. Run BEFORE the frontend rebuild.
--
-- Supersedes the get_dashboard_stats / get_device_mix_history definitions in
-- 13_analytics_read_functions.sql and the get_transition_mix override in
-- 40_transition_mix_prev_week.sql (those stay as historical layers; this file wins on apply).
-- The ie_eeros_model_daily column (04), refresh_eero_aggregates (09) and get_weekly_model_adds
-- (39) base files were updated in place to match.
-- ----------------------------------------------------------------------------

-- 1) ie_eeros_model_daily gains an organization dimension (forward-fill only). ---------------
ALTER TABLE public.ie_eeros_model_daily ADD COLUMN IF NOT EXISTS organization text;

-- 2) refresh_eero_aggregates: group ie_eeros_model_daily by organization too. ---------------
CREATE OR REPLACE FUNCTION public.refresh_eero_aggregates(p_report_date date DEFAULT NULL::date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_date date;
BEGIN
  IF p_report_date IS NOT NULL THEN
    DELETE FROM ie_eeros_model_daily WHERE report_date = p_report_date;
    INSERT INTO ie_eeros_model_daily (report_date, network_customer_type, organization, model, count)
    SELECT e.report_date, COALESCE(n.network_customer_type,''), e.organization, e.model, COUNT(*)::int
    FROM ie_eeros e
    LEFT JOIN ie_networks n ON n.network_id = e.network_id AND n.report_date = e.report_date
    WHERE e.report_date = p_report_date AND e.model IS NOT NULL
    GROUP BY e.report_date, COALESCE(n.network_customer_type,''), e.organization, e.model;
    INSERT INTO ie_eeros_first_seen (eero_serial, first_date, model)
    SELECT eero_serial, MIN(report_date), (array_agg(model ORDER BY report_date))[1]
    FROM ie_eeros WHERE report_date = p_report_date GROUP BY eero_serial
    ON CONFLICT (eero_serial) DO NOTHING;
    RETURN;
  END IF;

  FOR v_date IN
    SELECT d FROM (
      SELECT DISTINCT report_date AS d FROM ie_eeros
      EXCEPT
      SELECT DISTINCT report_date FROM ie_eeros_model_daily
    ) m ORDER BY d
  LOOP
    INSERT INTO ie_eeros_model_daily (report_date, network_customer_type, organization, model, count)
    SELECT e.report_date, COALESCE(n.network_customer_type,''), e.organization, e.model, COUNT(*)::int
    FROM ie_eeros e
    LEFT JOIN ie_networks n ON n.network_id = e.network_id AND n.report_date = e.report_date
    WHERE e.report_date = v_date AND e.model IS NOT NULL
    GROUP BY e.report_date, COALESCE(n.network_customer_type,''), e.organization, e.model;
    INSERT INTO ie_eeros_first_seen (eero_serial, first_date, model)
    SELECT eero_serial, MIN(report_date), (array_agg(model ORDER BY report_date))[1]
    FROM ie_eeros WHERE report_date = v_date GROUP BY eero_serial
    ON CONFLICT (eero_serial) DO NOTHING;
  END LOOP;
END;
$function$;

-- 3) get_dashboard_stats — filter the DEVICE counts by org (networks/signal are not device-org).
DROP FUNCTION IF EXISTS public.get_dashboard_stats(text, boolean);
CREATE OR REPLACE FUNCTION public.get_dashboard_stats(p_customer_type text DEFAULT NULL::text, p_filter_by_type boolean DEFAULT false, p_exclude_direct_sale boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
DECLARE
  v_report_date date;
  v_total_networks bigint;
  v_total_devices bigint;
  v_gateway_anomalies bigint;
  v_device_mix jsonb;
  v_signal_count bigint;
  v_acc_report_date date;
BEGIN
  SELECT report_date INTO v_report_date FROM ie_networks ORDER BY report_date DESC LIMIT 1;
  IF v_report_date IS NULL THEN
    RETURN jsonb_build_object('totalNetworks',0,'totalDevices',0,'gatewayAnomalies',0,
      'deviceMix','[]'::jsonb,'signalCount',0,'reportDate',NULL);
  END IF;

  -- totalNetworks (network-level — NOT filtered by device org)
  IF p_filter_by_type THEN
    IF p_customer_type IS NULL THEN
      SELECT COUNT(*) INTO v_total_networks FROM ie_networks WHERE report_date = v_report_date AND network_customer_type IS NULL;
    ELSE
      SELECT COUNT(*) INTO v_total_networks FROM ie_networks WHERE report_date = v_report_date AND network_customer_type = p_customer_type;
    END IF;
  ELSE
    SELECT COUNT(*) INTO v_total_networks FROM ie_networks WHERE report_date = v_report_date;
  END IF;

  -- totalDevices (device-level — filtered by org when excluding Direct Sale)
  IF p_filter_by_type THEN
    SELECT COUNT(*) INTO v_total_devices FROM ie_eeros e
    WHERE e.report_date = v_report_date
      AND (NOT p_exclude_direct_sale OR e.organization NOT ILIKE '%direct%')
      AND e.network_id IN (SELECT network_id FROM ie_networks
        WHERE report_date = v_report_date AND ((p_customer_type IS NULL AND network_customer_type IS NULL) OR network_customer_type = p_customer_type));
  ELSE
    SELECT COUNT(*) INTO v_total_devices FROM ie_eeros e
    WHERE e.report_date = v_report_date
      AND (NOT p_exclude_direct_sale OR e.organization NOT ILIKE '%direct%');
  END IF;

  -- gatewayAnomalies (device-level — filtered by org)
  IF p_filter_by_type THEN
    SELECT COUNT(*) INTO v_gateway_anomalies FROM (
      SELECT network_id FROM ie_eeros e
      WHERE e.report_date = v_report_date AND e.is_gateway = true
        AND (NOT p_exclude_direct_sale OR e.organization NOT ILIKE '%direct%')
        AND e.network_id IN (SELECT network_id FROM ie_networks
          WHERE report_date = v_report_date AND ((p_customer_type IS NULL AND network_customer_type IS NULL) OR network_customer_type = p_customer_type))
      GROUP BY network_id HAVING COUNT(*) > 1
    ) sub;
  ELSE
    SELECT COUNT(*) INTO v_gateway_anomalies FROM (
      SELECT network_id FROM ie_eeros e
      WHERE e.report_date = v_report_date AND e.is_gateway = true
        AND (NOT p_exclude_direct_sale OR e.organization NOT ILIKE '%direct%')
      GROUP BY network_id HAVING COUNT(*) > 1
    ) sub;
  END IF;

  -- deviceMix donut (device-level — filtered by org)
  IF p_filter_by_type THEN
    SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb) INTO v_device_mix FROM (
      SELECT model, COUNT(*)::int as count FROM ie_eeros e
      WHERE e.report_date = v_report_date AND e.model IS NOT NULL
        AND (NOT p_exclude_direct_sale OR e.organization NOT ILIKE '%direct%')
        AND e.network_id IN (SELECT network_id FROM ie_networks
          WHERE report_date = v_report_date AND ((p_customer_type IS NULL AND network_customer_type IS NULL) OR network_customer_type = p_customer_type))
      GROUP BY model ORDER BY count DESC LIMIT 10
    ) m;
  ELSE
    SELECT COALESCE(jsonb_agg(row_to_json(m)), '[]'::jsonb) INTO v_device_mix FROM (
      SELECT model, COUNT(*)::int as count FROM ie_eeros e
      WHERE e.report_date = v_report_date AND e.model IS NOT NULL
        AND (NOT p_exclude_direct_sale OR e.organization NOT ILIKE '%direct%')
      GROUP BY model ORDER BY count DESC LIMIT 10
    ) m;
  END IF;

  -- signalCount (accessories — NOT a device-org attribute, left unfiltered)
  SELECT MAX(report_date) INTO v_acc_report_date FROM ie_accessories;
  IF v_acc_report_date IS NULL THEN
    v_signal_count := 0;
  ELSIF p_filter_by_type THEN
    SELECT COUNT(*) INTO v_signal_count FROM ie_accessories a
    WHERE a.report_date = v_acc_report_date
      AND a.network_id IN (SELECT network_id FROM ie_networks
        WHERE report_date = v_report_date AND ((p_customer_type IS NULL AND network_customer_type IS NULL) OR network_customer_type = p_customer_type));
  ELSE
    SELECT COUNT(*) INTO v_signal_count FROM ie_accessories WHERE report_date = v_acc_report_date;
  END IF;

  RETURN jsonb_build_object('totalNetworks',v_total_networks,'totalDevices',v_total_devices,
    'gatewayAnomalies',v_gateway_anomalies,'deviceMix',v_device_mix,
    'signalCount',COALESCE(v_signal_count,0),'reportDate',v_report_date);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_dashboard_stats(text, boolean, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_dashboard_stats(text, boolean, boolean) TO authenticated;

-- 4) get_transition_mix — filter the scoped device set by org. ------------------------------
DROP FUNCTION IF EXISTS public.get_transition_mix(text, boolean);
CREATE OR REPLACE FUNCTION public.get_transition_mix(p_customer_type text DEFAULT NULL::text, p_filter_by_type boolean DEFAULT false, p_exclude_direct_sale boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
DECLARE
  v_latest_date date; v_week_start date; v_prev_week_start date; v_velocity_start date;
  v_current_mix jsonb; v_new_mix jsonb;
  v_outdoor7_count bigint; v_wifi7_count bigint; v_total_devices bigint;
  v_velocity numeric; v_velocity_days int;
BEGIN
  SELECT MAX(report_date) INTO v_latest_date FROM ie_eeros;
  IF v_latest_date IS NULL THEN
    RETURN jsonb_build_object('currentMix','[]'::jsonb,'newDevicesMix','[]'::jsonb,
      'wifi7Count',0,'outdoor7Count',0,'totalDevices',0,'latestDate',NULL,'wifi7Velocity',0,'velocityDays',0);
  END IF;
  v_week_start := date_trunc('week', v_latest_date::timestamp)::date;
  v_prev_week_start := v_week_start - 7;
  v_velocity_start := v_latest_date - 7;

  WITH scoped AS (
    SELECT e.eero_serial,
      CASE WHEN e.model IN ('eero Pro 6E','eero 7','eero Pro 7','eero Max 7','eero Outdoor 7') THEN e.model ELSE 'Other' END AS model,
      e.model AS raw_model,
      COALESCE(fs.first_date >= v_prev_week_start AND fs.first_date < v_week_start, false) AS is_new
    FROM ie_eeros e
    LEFT JOIN ie_eeros_first_seen fs ON fs.eero_serial = e.eero_serial
    WHERE e.report_date = v_latest_date
      AND (NOT p_exclude_direct_sale OR e.organization NOT ILIKE '%direct%')
      AND (NOT p_filter_by_type OR EXISTS (
        SELECT 1 FROM ie_networks n WHERE n.network_id = e.network_id AND n.report_date = v_latest_date
          AND ((p_customer_type IS NULL AND n.network_customer_type IS NULL) OR n.network_customer_type = p_customer_type)
      ))
  )
  SELECT
    (SELECT COALESCE(jsonb_agg(row_to_json(r) ORDER BY r.sort_order),'[]'::jsonb) FROM
      (SELECT model, COUNT(*)::int AS count,
        CASE model WHEN 'eero Pro 6E' THEN 1 WHEN 'eero 7' THEN 2 WHEN 'eero Pro 7' THEN 3 WHEN 'eero Max 7' THEN 4 WHEN 'eero Outdoor 7' THEN 5 ELSE 6 END AS sort_order
       FROM scoped GROUP BY model) r),
    (SELECT COALESCE(jsonb_agg(row_to_json(r) ORDER BY r.sort_order),'[]'::jsonb) FROM
      (SELECT model, COUNT(*)::int AS count,
        CASE model WHEN 'eero Pro 6E' THEN 1 WHEN 'eero 7' THEN 2 WHEN 'eero Pro 7' THEN 3 WHEN 'eero Max 7' THEN 4 WHEN 'eero Outdoor 7' THEN 5 ELSE 6 END AS sort_order
       FROM scoped WHERE is_new GROUP BY model) r),
    (SELECT COUNT(*) FROM scoped),
    (SELECT COUNT(*) FROM scoped WHERE raw_model IN ('eero 7','eero Pro 7','eero Max 7')),
    (SELECT COUNT(*) FROM scoped WHERE raw_model = 'eero Outdoor 7')
  INTO v_current_mix, v_new_mix, v_total_devices, v_wifi7_count, v_outdoor7_count;

  SELECT COALESCE(AVG(daily_count),0), COUNT(*) INTO v_velocity, v_velocity_days FROM (
    SELECT first_date, COUNT(*) AS daily_count FROM ie_eeros_first_seen
    WHERE model IN ('eero 7','eero Pro 7','eero Max 7') AND first_date >= v_velocity_start
    GROUP BY first_date
  ) daily;

  RETURN jsonb_build_object('currentMix',v_current_mix,'newDevicesMix',v_new_mix,
    'wifi7Count',COALESCE(v_wifi7_count,0),'outdoor7Count',COALESCE(v_outdoor7_count,0),
    'totalDevices',COALESCE(v_total_devices,0),'latestDate',v_latest_date,
    'wifi7Velocity',COALESCE(ROUND(v_velocity,1),0),'velocityDays',COALESCE(v_velocity_days,0));
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_transition_mix(text, boolean, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_transition_mix(text, boolean, boolean) TO authenticated;

-- 5) get_device_mix_history — filter the aggregate by org (NULL-safe: historical rows kept).
DROP FUNCTION IF EXISTS public.get_device_mix_history(text, boolean, text);
CREATE OR REPLACE FUNCTION public.get_device_mix_history(p_customer_type text DEFAULT NULL::text, p_filter_by_type boolean DEFAULT false, p_range text DEFAULT '90d'::text, p_exclude_direct_sale boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
DECLARE
  v_latest_date date; v_range_start date; v_median numeric; v_threshold numeric; v_result jsonb;
BEGIN
  SELECT MAX(report_date) INTO v_latest_date FROM ie_eeros_model_daily;
  IF v_latest_date IS NULL THEN RETURN '[]'::jsonb; END IF;
  v_range_start := CASE p_range WHEN '30d' THEN v_latest_date - 30 WHEN '1y' THEN v_latest_date - 365 ELSE v_latest_date - 90 END;

  WITH scoped AS (
    SELECT report_date, model, count FROM ie_eeros_model_daily
    WHERE report_date >= v_range_start
      AND (NOT p_filter_by_type OR network_customer_type = COALESCE(p_customer_type,''))
      AND (NOT p_exclude_direct_sale OR organization IS NULL OR organization NOT ILIKE '%direct%')
  ),
  daily_totals AS (SELECT report_date, SUM(count) AS total FROM scoped GROUP BY report_date)
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total) INTO v_median FROM daily_totals;

  v_threshold := COALESCE(v_median, 0) * 0.5;

  WITH scoped AS (
    SELECT report_date, model, count FROM ie_eeros_model_daily
    WHERE report_date >= v_range_start
      AND (NOT p_filter_by_type OR network_customer_type = COALESCE(p_customer_type,''))
      AND (NOT p_exclude_direct_sale OR organization IS NULL OR organization NOT ILIKE '%direct%')
  ),
  agg AS (SELECT report_date, model, SUM(count)::int AS count FROM scoped GROUP BY report_date, model),
  totals AS (SELECT report_date, SUM(count) AS total FROM agg GROUP BY report_date),
  good_dates AS (SELECT report_date FROM totals WHERE total >= v_threshold)
  SELECT COALESCE(jsonb_agg(row_to_json(d) ORDER BY d.report_date, d.model), '[]'::jsonb) INTO v_result FROM (
    SELECT a.report_date::text AS report_date, a.model, a.count
    FROM agg a JOIN good_dates g ON g.report_date = a.report_date
  ) d;

  RETURN v_result;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_device_mix_history(text, boolean, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_device_mix_history(text, boolean, text, boolean) TO authenticated;

-- 6) get_weekly_model_adds — anti-join the Direct-Sale serials (from the latest ie_eeros). ----
DROP FUNCTION IF EXISTS public.get_weekly_model_adds();
CREATE OR REPLACE FUNCTION public.get_weekly_model_adds(p_exclude_direct_sale boolean DEFAULT false)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '30s'
AS $function$
  WITH bounds AS (
    SELECT date_trunc('week', min(first_date))::date AS cutover_week,
           date_trunc('week', max(first_date))::date AS current_week
    FROM ie_eeros_first_seen
  ),
  direct_serials AS (
    SELECT DISTINCT eero_serial FROM ie_eeros WHERE organization ILIKE '%direct%'
  ),
  weekly AS (
    SELECT date_trunc('week', fs.first_date)::date AS week_start,
           CASE WHEN fs.model IN ('eero Pro 6E','eero 7','eero Pro 7','eero Max 7','eero Outdoor 7')
                THEN fs.model ELSE 'Other' END AS model,
           count(*)::int AS count
    FROM ie_eeros_first_seen fs
    WHERE date_trunc('week', fs.first_date)::date > (SELECT cutover_week FROM bounds)
      AND (NOT p_exclude_direct_sale OR NOT EXISTS (
        SELECT 1 FROM direct_serials ds WHERE ds.eero_serial = fs.eero_serial))
    GROUP BY 1, 2
  )
  SELECT jsonb_build_object(
    'currentWeekStart', (SELECT current_week FROM bounds),
    'rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'week_start',  week_start,
        'week_ending', (week_start + 6),
        'model',       model,
        'count',       count
      ) ORDER BY week_start, model)
      FROM weekly
    ), '[]'::jsonb)
  );
$function$;
REVOKE EXECUTE ON FUNCTION public.get_weekly_model_adds(boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_weekly_model_adds(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
