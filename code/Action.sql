-- =====================================================================
-- Process:
-- Step1: 匹配inputevents中目标液体/升压药事件
-- Step2: 对药物进行归一化处理
-- Step3: 异常值处理
-- Step4: 按液体输入事件与4小时事件窗口重叠时间，分配
-- Step5: 汇总
-- =====================================================================

-- DROP TABLE IF EXISTS Action.sepsis3_cohort_nosofa;

CREATE TABLE Action.sepsis3_cohort_action AS
SELECT
    subject_id,
    hadm_id,
    stay_id,
    -- anchor_age,
    -- first_careunit,
    -- last_careunit,
    -- admittime,
    -- dischtime,
    -- intime,
    -- outtime,
    -- ab_id,
    -- antibiotic,
    -- antibiotic_time,
    -- culture_time,
    -- suspected_infection_time,
    -- raw_sepsis_onset_time,
    -- 去掉 SOFA 分值/分项：
    -- onset_sofa2_score,
    -- baseline_sofa2,
    -- delta_sofa2,
    -- brain,
    -- respiratory,
    -- cardiovascular,
    -- liver,
    -- kidney,
    -- hemostasis,
    -- baseline_observed,
    -- onset_hour_from_icu,
    -- onset_hour_from_hosp,
    -- sofa_after_suspected_infection_hr,
    -- is_adult,
    -- valid_icu_time,
    -- valid_hosp_time,
    -- onset_before_hosp,
    -- onset_after_hosp,
    -- onset_before_icu,
    -- onset_after_icu,
    trajectory_start_time,
    trajectory_end_time,
    icu_los_hours,
    trajectory_los_hours,
    n_complete_4h_windows
    -- source_file,
    -- loaded_at,
    -- hf_chronic,
    -- uremia
FROM Exclusion.Sepsis3_Cohort;  




USE Action;

-- DROP TABLE IF EXISTS seq_0_999;
-- DROP TABLE IF EXISTS trajectory_4h_from_sepsis3;
-- DROP TABLE IF EXISTS treatment_events_step1;
-- DROP TABLE IF EXISTS fluid_events_step2;
-- DROP TABLE IF EXISTS vaso_events_step2;
-- DROP TABLE IF EXISTS fluid_events_step3;
-- DROP TABLE IF EXISTS vaso_events_step3;
-- DROP TABLE IF EXISTS fluid_overlap_step4;
-- DROP TABLE IF EXISTS vaso_overlap_step4;
-- DROP TABLE IF EXISTS fluid_action_step5;
-- DROP TABLE IF EXISTS vaso_action_step5;
-- DROP TABLE IF EXISTS treatment_action_step5;

-- windows数量分布情况
-- 查看最大值、最小值、均值
-- results: max_win=957, min_win=1
SELECT 
    MAX(n_complete_4h_windows) AS max_win,
    MIN(n_complete_4h_windows) AS min_win,
    AVG(n_complete_4h_windows) AS avg_win
FROM Action.sepsis3_cohort_action;
-- 查看频数分布：每个窗口数量对应的患者数
-- 运行结果：整体呈现右偏
SELECT n_complete_4h_windows, COUNT(DISTINCT stay_id) AS patient_count
FROM Action.sepsis3_cohort_action
GROUP BY n_complete_4h_windows
ORDER BY n_complete_4h_windows;



-- 生成 0~999 的序号表，用于展开 4 小时窗口
-- DROP TABLE IF EXISTS seq_0_999;
CREATE TABLE seq_0_999 (n INT PRIMARY KEY);
INSERT INTO seq_0_999(n)
SELECT a.n + b.n*10 + c.n*100 AS n
FROM
(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
CROSS JOIN
(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
CROSS JOIN
(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
WHERE a.n + b.n*10 + c.n*100 <= 999;

-- 由 Sepsis3 cohort 展开 4 小时窗口
CREATE TABLE trajectory_4h_from_sepsis3 ENGINE=MyISAM AS
SELECT
    c.subject_id,
    c.hadm_id,
    c.stay_id,
    s.n + 1 AS window_index,
    DATE_ADD(c.trajectory_start_time, INTERVAL 4 * s.n HOUR) AS window_start,
    DATE_ADD(c.trajectory_start_time, INTERVAL 4 * (s.n + 1) HOUR) AS window_end,
    c.trajectory_start_time,
    c.trajectory_end_time
FROM sepsis3_cohort_action c
JOIN seq_0_999 s
  ON s.n < c.n_complete_4h_windows;

ALTER TABLE trajectory_4h_from_sepsis3
    ADD UNIQUE INDEX pk_traj_4h (stay_id, window_index),
    ADD INDEX idx_traj_4h_time (stay_id, window_start, window_end);


-- =====================================================================
-- Step1: 匹配 inputevents 中目标液体/升压药事件
-- =====================================================================
CREATE TABLE treatment_events_step1 ENGINE=MyISAM AS
SELECT
    c.subject_id,
    c.hadm_id,
    c.stay_id,
    c.trajectory_start_time,
    c.trajectory_end_time,
    ie.itemid,
    m.treatment_class,
    m.treatment_name,
    m.treatment_subtype,
    -- 事件开始时间定义：event_start = inputevents.starttime
    ie.starttime AS event_start,
    -- 事件结束时间定义：1.如果存在inputevents.endtime,则event_end = inputevents.endtime
    --                 2.如果是Bolus(单次推注，不是持续泵注)，没有endtime, 所以event_end = inputevents.starttime + 1min
    --                 3.其余情况为null
    CASE
        WHEN ie.endtime IS NOT NULL AND ie.endtime > ie.starttime THEN ie.endtime
        WHEN ie.statusdescription = 'Bolus' AND ie.starttime IS NOT NULL THEN DATE_ADD(ie.starttime, INTERVAL 1 MINUTE)
        ELSE NULL
    END AS event_end,
    -- 事件总持续描述
    TIMESTAMPDIFF(SECOND, ie.starttime,
        CASE
            WHEN ie.endtime IS NOT NULL AND ie.endtime > ie.starttime THEN ie.endtime
            WHEN ie.statusdescription = 'Bolus' AND ie.starttime IS NOT NULL THEN DATE_ADD(ie.starttime, INTERVAL 1 MINUTE)
            ELSE NULL
        END
    ) AS event_duration_seconds,
    -- 事件落在trajectory的重叠秒数
    TIMESTAMPDIFF(
        SECOND,
        GREATEST(ie.starttime, c.trajectory_start_time),
        LEAST(
            CASE
                WHEN ie.endtime IS NOT NULL AND ie.endtime > ie.starttime THEN ie.endtime
                WHEN ie.statusdescription = 'Bolus' AND ie.starttime IS NOT NULL THEN DATE_ADD(ie.starttime, INTERVAL 1 MINUTE)
                ELSE NULL
            END,
            c.trajectory_end_time
        )
    ) AS trajectory_overlap_seconds,
    -- 保留原始inputevents中的剂量，速率等，暂时不做归一化处理。
    ie.amount,
    ie.amountuom,
    ie.rate,
    ie.rateuom,
    ie.patientweight,
    ie.statusdescription,
    ie.orderid,
    ie.linkorderid
FROM sepsis3_cohort_action c
JOIN MIMIC_IV.inputevents ie
  ON ie.stay_id = c.stay_id
  -- inputevents 字典映射表
JOIN (
    SELECT 225158 AS itemid, 'fluid' AS treatment_class, 'normal_saline_0_9' AS treatment_name, 'crystalloid_saline' AS treatment_subtype
    UNION ALL SELECT 225828, 'fluid', 'lactated_ringers', 'crystalloid_balanced'
    UNION ALL SELECT 220864, 'fluid', 'albumin_5_percent', 'albumin'
    UNION ALL SELECT 220862, 'fluid', 'albumin_25_percent', 'albumin'
    UNION ALL SELECT 221906, 'vasopressor', 'norepinephrine', 'catecholamine'
    UNION ALL SELECT 221289, 'vasopressor', 'epinephrine', 'catecholamine'
    UNION ALL SELECT 221749, 'vasopressor', 'phenylephrine', 'catecholamine'
    UNION ALL SELECT 221662, 'vasopressor', 'dopamine', 'catecholamine'
    UNION ALL SELECT 222315, 'vasopressor', 'vasopressin', 'vasopressin'
) m
  ON ie.itemid = m.itemid
WHERE ie.starttime IS NOT NULL
  AND ie.endtime IS NOT NULL
  AND ie.endtime > ie.starttime
  AND ie.endtime > c.trajectory_start_time
  AND ie.starttime < c.trajectory_end_time;

ALTER TABLE treatment_events_step1
    ADD INDEX idx_step1_stay_time (stay_id, event_start, event_end),
    ADD INDEX idx_step1_class (treatment_class),
    ADD INDEX idx_step1_item (itemid);


-- =====================================================================
-- Step2: 对药物进行归一化处理
-- =====================================================================

-- 确认涉及到的计量单位
-- fluid_amountuom: L, mL
-- fluid_rateuom；mL/hour, mL/min, µL/kg/min
-- vasopressor_amountuom: mg, units
-- vasopressor_rateuom: mcg/kg/min, units/hour
SELECT DISTINCT
    treatment_class,
    amountuom,
    rateuom
FROM Action.treatment_events_step1
ORDER BY treatment_class, amountuom, rateuom;

-- 液体：统一成 mL
CREATE TABLE fluid_events_step2 ENGINE=MyISAM AS
SELECT
    s.*,
    CASE
        WHEN s.amount IS NOT NULL AND s.amount > 0 AND s.amountuom = 'mL'
            THEN s.amount
        WHEN s.amount IS NOT NULL AND s.amount > 0 AND s.amountuom = 'L'
            THEN s.amount * 1000
        WHEN s.amount IS NULL AND s.rate IS NOT NULL AND s.rate > 0 AND s.rateuom = 'mL/hour'
            THEN s.rate * s.event_duration_seconds / 3600.0
        WHEN s.amount IS NULL AND s.rate IS NOT NULL AND s.rate > 0 AND s.rateuom = 'mL/min'
            THEN s.rate * s.event_duration_seconds / 60.0
        ELSE NULL
    END AS amount_ml
FROM treatment_events_step1 s
WHERE s.treatment_class = 'fluid';

-- 升压药：统一成标准速率，并计算去甲肾上腺素当量
CREATE TABLE vaso_events_step2 ENGINE=MyISAM AS
SELECT
    z.*,
    -- norepinephrine equiv rate: 
    -- Norepinephrine (1:1)
    -- Epinephrine (1:1)
    -- Phenylephrine (1:10)
    -- Dopamine (1:100)
    -- Vasopressin (1 unit/min = 2.5 mcg/kg/min)
    CASE
        WHEN z.norepinephrine_rate_mcg_kg_min IS NULL
         AND z.epinephrine_rate_mcg_kg_min IS NULL
         AND z.phenylephrine_rate_mcg_kg_min IS NULL
         AND z.dopamine_rate_mcg_kg_min IS NULL
         AND z.vasopressin_rate_units_min IS NULL
        THEN NULL
        ELSE
            COALESCE(z.norepinephrine_rate_mcg_kg_min, 0)
          + COALESCE(z.epinephrine_rate_mcg_kg_min, 0)
          + COALESCE(z.phenylephrine_rate_mcg_kg_min, 0) / 10.0
          + COALESCE(z.dopamine_rate_mcg_kg_min, 0) / 100.0
          + COALESCE(z.vasopressin_rate_units_min, 0) * 2.5
    END AS norepinephrine_equiv_rate_mcg_kg_min
FROM (
    SELECT
        s.*,
        -- 只保留20~300的合理体重，超出范围直接NULL
        CASE WHEN s.patientweight BETWEEN 20 AND 300 THEN s.patientweight ELSE NULL END AS patientweight_valid,
        -- 统一为：mcg/kg/min
        CASE
            WHEN s.itemid = 221906 AND s.rate > 0 AND s.rateuom = 'mcg/kg/min' THEN s.rate
            WHEN s.itemid = 221906 AND s.rate > 0 AND s.rateuom = 'mg/kg/min' THEN s.rate * 1000
            WHEN s.itemid = 221906 AND s.rate > 0 AND s.rateuom = 'mcg/min' AND s.patientweight BETWEEN 20 AND 300 THEN s.rate / s.patientweight
            ELSE NULL
        END AS norepinephrine_rate_mcg_kg_min,
        -- 统一为：mcg/kg/min
        CASE
            WHEN s.itemid = 221289 AND s.rate > 0 AND s.rateuom = 'mcg/kg/min' THEN s.rate
            WHEN s.itemid = 221289 AND s.rate > 0 AND s.rateuom = 'mg/kg/min' THEN s.rate * 1000
            WHEN s.itemid = 221289 AND s.rate > 0 AND s.rateuom = 'mcg/min' AND s.patientweight BETWEEN 20 AND 300 THEN s.rate / s.patientweight
            ELSE NULL
        END AS epinephrine_rate_mcg_kg_min,
        -- 统一为：mcg/kg/min
        CASE
            WHEN s.itemid = 221749 AND s.rate > 0 AND s.rateuom = 'mcg/kg/min' THEN s.rate
            WHEN s.itemid = 221749 AND s.rate > 0 AND s.rateuom = 'mg/kg/min' THEN s.rate * 1000
            WHEN s.itemid = 221749 AND s.rate > 0 AND s.rateuom = 'mcg/min' AND s.patientweight BETWEEN 20 AND 300 THEN s.rate / s.patientweight
            ELSE NULL
        END AS phenylephrine_rate_mcg_kg_min,
        -- 统一为：mcg/kg/min
        CASE
            WHEN s.itemid = 221662 AND s.rate > 0 AND s.rateuom = 'mcg/kg/min' THEN s.rate
            WHEN s.itemid = 221662 AND s.rate > 0 AND s.rateuom = 'mg/kg/min' THEN s.rate * 1000
            WHEN s.itemid = 221662 AND s.rate > 0 AND s.rateuom = 'mcg/min' AND s.patientweight BETWEEN 20 AND 300 THEN s.rate / s.patientweight
            ELSE NULL
        END AS dopamine_rate_mcg_kg_min,
        -- 统一为：units/min
        CASE
            WHEN s.itemid = 222315 AND s.rate > 0 AND s.rateuom = 'units/min' THEN s.rate
            WHEN s.itemid = 222315 AND s.rate > 0 AND s.rateuom = 'units/hour' THEN s.rate / 60.0
            ELSE NULL
        END AS vasopressin_rate_units_min
    FROM treatment_events_step1 s
    WHERE s.treatment_class = 'vasopressor'
) z;



-- =====================================================================
-- Step3: 异常值处理
-- =====================================================================

-- 3.1 fluid异常值处理
-- 剔除逻辑：
-- ①剔除空记录 / 0 剂量
-- ②单条输液总量≥100000 mL
-- ③事件时长<0
-- ④和trajectory无交集
CREATE TABLE fluid_events_step3 ENGINE=MyISAM AS
SELECT
    s.*,
    s.amount_ml * s.trajectory_overlap_seconds / s.event_duration_seconds AS amount_ml_in_trajectory
FROM fluid_events_step2 s
WHERE s.amount_ml IS NOT NULL
  AND s.amount_ml > 0
  AND s.amount_ml <= 100000
  AND s.event_duration_seconds > 0
  AND s.trajectory_overlap_seconds > 0;

-- 3.2 vaso异常值处理
-- 保留以下：
-- ①norepinephrine ≤10 mcg/kg/min
-- ②epinephrine ≤10 mcg/kg/min
-- ③phenylephrine ≤100 mcg/kg/min
-- ④dopamine ≤100 mcg/kg/min
-- ⑤vasopressin ≤1 unit/min
CREATE TABLE vaso_events_step3 ENGINE=MyISAM AS
SELECT *
FROM vaso_events_step2
WHERE (
        norepinephrine_rate_mcg_kg_min IS NOT NULL
     OR epinephrine_rate_mcg_kg_min IS NOT NULL
     OR phenylephrine_rate_mcg_kg_min IS NOT NULL
     OR dopamine_rate_mcg_kg_min IS NOT NULL
     OR vasopressin_rate_units_min IS NOT NULL
)
  AND COALESCE(statusdescription, '') <> 'Bolus'
  AND (norepinephrine_rate_mcg_kg_min IS NULL OR norepinephrine_rate_mcg_kg_min <= 10)
  AND (epinephrine_rate_mcg_kg_min IS NULL OR epinephrine_rate_mcg_kg_min <= 10)
  AND (phenylephrine_rate_mcg_kg_min IS NULL OR phenylephrine_rate_mcg_kg_min <= 100)
  AND (dopamine_rate_mcg_kg_min IS NULL OR dopamine_rate_mcg_kg_min <= 100)
  AND (vasopressin_rate_units_min IS NULL OR vasopressin_rate_units_min <= 1)
  AND event_duration_seconds > 0
  AND trajectory_overlap_seconds > 0;

ALTER TABLE fluid_events_step3
    ADD INDEX idx_fluid_step3_stay_time (stay_id, event_start, event_end);

ALTER TABLE vaso_events_step3
    ADD INDEX idx_vaso_step3_stay_time (stay_id, event_start, event_end),
    ADD INDEX idx_vaso_step3_nee (norepinephrine_equiv_rate_mcg_kg_min);


-- =====================================================================
-- Step4: 按液体/升压药事件与 4 小时窗口重叠时间分配
-- =====================================================================

CREATE TABLE fluid_overlap_step4 ENGINE=MyISAM AS
SELECT
    t.subject_id,
    t.hadm_id,
    t.stay_id,
    t.window_index,
    t.window_start,
    t.window_end,
    f.itemid,
    f.treatment_name AS fluid_name,
    f.treatment_subtype AS fluid_subtype,
    f.event_start,
    f.event_end,
    TIMESTAMPDIFF(
        SECOND,
        GREATEST(f.event_start, t.window_start),
        LEAST(f.event_end, t.window_end)
    ) AS overlap_seconds,
    f.amount_ml,
    f.amount_ml *
        TIMESTAMPDIFF(
            SECOND,
            GREATEST(f.event_start, t.window_start),
            LEAST(f.event_end, t.window_end)
        ) / f.event_duration_seconds AS allocated_amount_ml,
    f.statusdescription
FROM trajectory_4h_from_sepsis3 t
JOIN fluid_events_step3 f
  ON t.stay_id = f.stay_id
 AND f.event_end > t.window_start
 AND f.event_start < t.window_end;

CREATE TABLE vaso_overlap_step4 ENGINE=MyISAM AS
SELECT
    t.subject_id,
    t.hadm_id,
    t.stay_id,
    t.window_index,
    t.window_start,
    t.window_end,
    v.itemid,
    v.treatment_name AS vasopressor_name,
    v.event_start,
    v.event_end,
    TIMESTAMPDIFF(
        SECOND,
        GREATEST(v.event_start, t.window_start),
        LEAST(v.event_end, t.window_end)
    ) / 60.0 AS overlap_minutes,
    v.norepinephrine_rate_mcg_kg_min,
    v.epinephrine_rate_mcg_kg_min,
    v.phenylephrine_rate_mcg_kg_min,
    v.dopamine_rate_mcg_kg_min,
    v.vasopressin_rate_units_min,
    v.norepinephrine_equiv_rate_mcg_kg_min,
    v.statusdescription
FROM trajectory_4h_from_sepsis3 t
JOIN vaso_events_step3 v
  ON t.stay_id = v.stay_id
 AND v.event_end > t.window_start
 AND v.event_start < t.window_end;

ALTER TABLE fluid_overlap_step4
    ADD INDEX idx_fluid_overlap_key (stay_id, window_index);

ALTER TABLE vaso_overlap_step4
    ADD INDEX idx_vaso_overlap_key (stay_id, window_index);


-- =====================================================================
-- Step5: 划分为5*5 action table
-- =====================================================================
-- DROP TABLE IF EXISTS fluid_action_step5;
CREATE TABLE fluid_action_step5 ENGINE=MyISAM AS
SELECT
    t.subject_id,
    t.hadm_id,
    t.stay_id,
    t.window_index,
    t.window_start,
    t.window_end,

    COALESCE(SUM(o.allocated_amount_ml), 0) AS total_fluid_ml,
    COALESCE(SUM(CASE WHEN o.fluid_subtype IN ('crystalloid_saline', 'crystalloid_balanced') THEN o.allocated_amount_ml END), 0) AS crystalloid_ml,
    COALESCE(SUM(CASE WHEN o.fluid_subtype = 'crystalloid_saline' THEN o.allocated_amount_ml END), 0) AS saline_ml,
    COALESCE(SUM(CASE WHEN o.fluid_subtype = 'crystalloid_balanced' THEN o.allocated_amount_ml END), 0) AS balanced_crystalloid_ml,
    COALESCE(SUM(CASE WHEN o.fluid_subtype = 'albumin' THEN o.allocated_amount_ml END), 0) AS albumin_ml,
    COALESCE(SUM(CASE WHEN o.fluid_name = 'albumin_5_percent' THEN o.allocated_amount_ml END), 0) AS albumin_5_ml,
    COALESCE(SUM(CASE WHEN o.fluid_name = 'albumin_25_percent' THEN o.allocated_amount_ml END), 0) AS albumin_25_ml,

    COUNT(o.itemid) AS fluid_record_count,
    CASE WHEN COUNT(o.itemid) > 0 THEN 1 ELSE 0 END AS fluid_any
FROM trajectory_4h_from_sepsis3 t
LEFT JOIN fluid_overlap_step4 o
  ON t.stay_id = o.stay_id
 AND t.window_index = o.window_index
GROUP BY
    t.subject_id,
    t.hadm_id,
    t.stay_id,
    t.window_index,
    t.window_start,
    t.window_end;
ALTER TABLE fluid_action_step5
    ADD UNIQUE INDEX pk_fluid_action_step5 (stay_id, window_index);
    
CREATE TABLE vaso_action_step5 ENGINE=MyISAM AS
SELECT
    t.subject_id,
    t.hadm_id,
    t.stay_id,
    t.window_index,
    t.window_start,
    t.window_end,

    COALESCE(SUM(o.norepinephrine_rate_mcg_kg_min * o.overlap_minutes) / 240.0, 0) AS norepinephrine_twa_mcg_kg_min,
    COALESCE(SUM(o.epinephrine_rate_mcg_kg_min * o.overlap_minutes) / 240.0, 0) AS epinephrine_twa_mcg_kg_min,
    COALESCE(SUM(o.phenylephrine_rate_mcg_kg_min * o.overlap_minutes) / 240.0, 0) AS phenylephrine_twa_mcg_kg_min,
    COALESCE(SUM(o.dopamine_rate_mcg_kg_min * o.overlap_minutes) / 240.0, 0) AS dopamine_twa_mcg_kg_min,
    COALESCE(SUM(o.vasopressin_rate_units_min * o.overlap_minutes) / 240.0, 0) AS vasopressin_twa_units_min,

    COALESCE(SUM(o.norepinephrine_equiv_rate_mcg_kg_min * o.overlap_minutes) / 240.0, 0) AS nee_twa_mcg_kg_min,
    COALESCE(MAX(o.norepinephrine_equiv_rate_mcg_kg_min), 0) AS nee_max_mcg_kg_min,

    COALESCE(SUM(o.overlap_minutes), 0) AS vasopressor_event_overlap_minutes,
    COUNT(o.itemid) AS vasopressor_record_count,
    CASE WHEN COUNT(o.itemid) > 0 THEN 1 ELSE 0 END AS vasopressor_any
FROM trajectory_4h_from_sepsis3 t
LEFT JOIN vaso_overlap_step4 o
  ON t.stay_id = o.stay_id
 AND t.window_index = o.window_index
GROUP BY
    t.subject_id,
    t.hadm_id,
    t.stay_id,
    t.window_index,
    t.window_start,
    t.window_end;
ALTER TABLE vaso_action_step5
    ADD UNIQUE INDEX pk_vaso_action_step5 (stay_id, window_index);
    

-- 合并fluid & vaso
CREATE TABLE treatment_action ENGINE=MyISAM AS
SELECT
    t.subject_id,
    t.hadm_id,
    t.stay_id,
    t.window_index,
    t.window_start,
    t.window_end,

    f.total_fluid_ml,
    f.crystalloid_ml,
    f.saline_ml,
    f.balanced_crystalloid_ml,
    f.albumin_ml,
    f.albumin_5_ml,
    f.albumin_25_ml,
    f.fluid_record_count,
    f.fluid_any,

    v.norepinephrine_twa_mcg_kg_min,
    v.epinephrine_twa_mcg_kg_min,
    v.phenylephrine_twa_mcg_kg_min,
    v.dopamine_twa_mcg_kg_min,
    v.vasopressin_twa_units_min,
    v.nee_twa_mcg_kg_min,
    v.nee_max_mcg_kg_min,
    v.vasopressor_event_overlap_minutes,
    v.vasopressor_record_count,
    v.vasopressor_any,

    CASE WHEN f.fluid_any = 1 OR v.vasopressor_any = 1 THEN 1 ELSE 0 END AS any_treatment_action
FROM trajectory_4h_from_sepsis3 t
JOIN fluid_action_step5 f
  ON t.stay_id = f.stay_id
 AND t.window_index = f.window_index
JOIN vaso_action_step5 v
  ON t.stay_id = v.stay_id
 AND t.window_index = v.window_index;

ALTER TABLE treatment_action
    ADD UNIQUE INDEX pk_treatment_action_step5 (stay_id, window_index);
