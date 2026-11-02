-- 索引
CREATE INDEX idx_diag_hadm_ver ON MIMIC_IV.diagnoses_icd (hadm_id, icd_version, icd_code);
CREATE INDEX idx_proc_hadm_ver ON MIMIC_hosp.procedures_icd (hadm_id, icd_version, icd_code);
CREATE INDEX idx_cs_stay_chart ON MIMIC_icu.code_status (stay_id, charttime);
CREATE INDEX idx_pe_stay_start ON MIMIC_icu.procedureevents (stay_id, starttime, itemid);


USE Exclusion;
-- 输入SOFA2, First_icu n=29,488
-- DROP TABLE IF EXISTS cohort_input;
CREATE TABLE cohort_input (
    subject_id                 BIGINT       NOT NULL,
    hadm_id                    BIGINT       NOT NULL,
    stay_id                    BIGINT       NOT NULL,
    anchor_age                 INT          NOT NULL,
    first_careunit             VARCHAR(100) NULL,
    last_careunit              VARCHAR(100) NULL,
    admittime                  DATETIME     NULL,
    dischtime                  DATETIME     NULL,
    intime                     DATETIME     NULL,
    outtime                    DATETIME     NULL,
    ab_id                      BIGINT       NULL,
    antibiotic                 VARCHAR(255) NULL,
    antibiotic_time            DATETIME     NULL,
    culture_time               DATETIME     NULL,
    suspected_infection_time   DATETIME     NULL,
    raw_sepsis_onset_time      DATETIME     NOT NULL,
    onset_sofa2_score          TINYINT      NOT NULL,
    baseline_sofa2             TINYINT      NOT NULL,
    baseline_observed          TINYINT(1)   NULL,
    delta_sofa2                TINYINT      NOT NULL,
    brain                      TINYINT      NULL,
    respiratory                TINYINT      NULL,
    cardiovascular             TINYINT      NULL,
    liver                      TINYINT      NULL,
    kidney                     TINYINT      NULL,
    hemostasis                 TINYINT      NULL,
    onset_hour_from_icu        DOUBLE       NULL,
    onset_hour_from_hosp       DOUBLE       NULL,
    sofa_after_suspected_infection_hr DOUBLE NULL,
    is_adult                   TINYINT(1)   NOT NULL,
    valid_icu_time             TINYINT(1)   NOT NULL,
    valid_hosp_time            TINYINT(1)   NOT NULL,
    onset_before_hosp          TINYINT(1)   NOT NULL,
    onset_after_hosp           TINYINT(1)   NOT NULL,
    onset_before_icu           TINYINT(1)   NOT NULL,
    onset_after_icu            TINYINT(1)   NOT NULL,
    trajectory_start_time      DATETIME     NOT NULL,
    trajectory_end_time        DATETIME     NOT NULL,
    icu_los_hours              DOUBLE       NULL,
    trajectory_los_hours       DOUBLE       NULL,
    n_complete_4h_windows      INT          NOT NULL,
    source_file                VARCHAR(100) NOT NULL DEFAULT 'sepsis3_cohort_final_clean.csv',
    loaded_at                  DATETIME     NOT NULL,
    hf_chronic                 TINYINT(1)   NULL,
    uremia                     TINYINT(1)   NULL,
    PRIMARY KEY (stay_id),
    UNIQUE KEY uq_s3_clean_subject (subject_id),
    INDEX idx_s3_clean_hadm (hadm_id),
    INDEX idx_s3_clean_onset (raw_sepsis_onset_time),
    INDEX idx_s3_clean_traj_start (trajectory_start_time),
    INDEX idx_s3_clean_hf (hf_chronic),
    INDEX idx_s3_clean_uremia (uremia)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
-- 统计结果：step0_n=28,923
SELECT COUNT(DISTINCT stay_id) AS step0_n FROM cohort_input; 


-- Exclusion part
-- ======================
-- 全局临时表：T0前最近一次curr_service
-- ======================
-- DROP TABLE IF EXISTS tmp_sv_t0_global;
CREATE TABLE tmp_sv_t0_global AS
SELECT
    sv.hadm_id,
    sv.curr_service
FROM MIMIC_hosp.services sv
INNER JOIN Exclusion.cohort_input c
    ON sv.hadm_id = c.hadm_id
WHERE sv.transfertime <= c.trajectory_start_time
AND sv.transfertime = (
    SELECT MAX(sv2.transfertime)
    FROM MIMIC_hosp.services sv2
    WHERE sv2.hadm_id = sv.hadm_id
      AND sv2.transfertime <= (
          SELECT trajectory_start_time
          FROM Exclusion.cohort_input
          WHERE hadm_id = sv2.hadm_id
      )
);
-- ======================
-- 全局临时表：T0时刻当下所在careunit
-- ======================
-- DROP TABLE IF EXISTS tmp_tf_t0_global;
CREATE TABLE tmp_tf_t0_global AS
SELECT DISTINCT
    tf.hadm_id,
    tf.careunit
FROM MIMIC_hosp.transfers tf
INNER JOIN Exclusion.cohort_input c
    ON tf.hadm_id = c.hadm_id
WHERE tf.intime <= c.trajectory_start_time
  AND (tf.outtime IS NULL OR c.trajectory_start_time < tf.outtime);

-- 建索引
CREATE INDEX idx_tmp_sv_global_hadm ON tmp_sv_t0_global(hadm_id);
CREATE INDEX idx_tmp_tf_global_hadm ON tmp_tf_t0_global(hadm_id);



-- Step1: 剔除 Brain death / organ-donor management  
--   脑死亡诊断:  ICD-10 G9382; Z005; Z52  /  ICD-9 34882; V59
--   器官摘取手术: ICD-10-PCS ^0TY  /  ICD-9 摘取相关编码
-- DROP TABLE IF EXISTS Exclusion.cohort_Brain_step1;
CREATE TABLE Exclusion.cohort_Brain_step1 AS
SELECT a.*
FROM Exclusion.cohort_input a
LEFT JOIN (
    SELECT DISTINCT di.hadm_id
    FROM MIMIC_IV.diagnoses_icd di
    LEFT JOIN MIMIC_IV.d_icd_diagnoses dd
        ON di.icd_code = dd.icd_code AND di.icd_version = dd.icd_version
    WHERE (
        (di.icd_version = 10 AND di.icd_code = 'G9382')
        OR (di.icd_version = 10 AND di.icd_code = 'Z05')
        OR (di.icd_version = 10 AND di.icd_code LIKE 'Z52%')
        OR (di.icd_version = 9  AND di.icd_code = '34882')
        OR (di.icd_version = 9  AND di.icd_code LIKE 'V59%')
    )
) bd ON a.hadm_id = bd.hadm_id 
WHERE bd.hadm_id IS NULL; 
-- 统计剔除结果: diff_n=101
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_input) AS step0_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Brain_step1) AS step1_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_input)
  - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Brain_step1) AS diff_n;



-- Step2: 剔除 Acute burns >10% TBSA  
--   ICD-10: T31.1–T31.9 (烧伤累及体表面积 ≥10%)
--   ICD-9 : 948.10–948.99
-- DROP TABLE IF EXISTS Exclusion.cohort_Burn_step2;
CREATE TABLE Exclusion.cohort_Burn_step2 AS
SELECT a.*
FROM Exclusion.cohort_Brain_step1 a
LEFT JOIN (
    SELECT DISTINCT hadm_id FROM MIMIC_IV.diagnoses_icd
    WHERE (icd_version = 10 AND icd_code REGEXP '^T31[1-9]')
       OR (icd_version = 9  AND icd_code REGEXP '^948[1-9]')
) burn ON a.hadm_id = burn.hadm_id
WHERE burn.hadm_id IS NULL;
-- 统计剔除结果: step1_n=28,822; step2_n=28,819; diff_n=3
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Brain_step1) AS step1_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Burn_step2) AS step2_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Brain_step1)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Burn_step2) AS diff_n;



-- Step3: 剔除CMO（仅舒适治疗目标）
-- DROP TABLE IF EXISTS Exclusion.cohort_CMO_step3;
CREATE TABLE Exclusion.cohort_CMO_step3 AS
SELECT a.*
FROM Exclusion.cohort_Burn_step2 a
LEFT JOIN (
    SELECT DISTINCT ce.stay_id, ce.charttime
    FROM MIMIC_IV.chartevents ce
    INNER JOIN MIMIC_IV.d_items di ON ce.itemid = di.itemid
    WHERE UPPER(di.label) REGEXP 'CODE STATUS|RESUSCITATION STATUS|GOALS OF CARE|LEVEL OF CARE'
      AND UPPER(ce.value) REGEXP 'COMFORT|CMO|WITHDRAW|CARE AND COMFORT'
) cmo ON a.stay_id = cmo.stay_id AND cmo.charttime < a.trajectory_start_time
WHERE cmo.stay_id IS NULL;

-- 统计剔除结果: diff_n=1
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Burn_step2) AS step2_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_CMO_step3) AS step3_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Burn_step2)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_CMO_step3) AS diff_n;




-- Step4: 剔除 Active major bleeding  
--   ICD-10: R571,T794  /  ICD-9: 9584,78559
-- 剔除条件 = 有大出血ICD诊断 AND 12h窗口内血制品事件数 >= 2
-- DROP TABLE IF EXISTS Exclusion.cohort_Bleeding_step4;
CREATE TABLE Exclusion.cohort_Bleeding_step4 AS
SELECT base.*
FROM Exclusion.cohort_CMO_step3 base
WHERE base.stay_id NOT IN (
    -- 子查询：找出所有需要被剔除的stay_id
    SELECT DISTINCT sub.stay_id
    FROM (
        SELECT
            a.stay_id,
            a.hadm_id,
            a.trajectory_start_time,
            CASE WHEN bleed.hadm_id IS NOT NULL THEN 1 ELSE 0 END AS has_major_bleed,
            COUNT(bp.stay_id) AS bp_count_12h
        FROM Exclusion.cohort_CMO_step3 a
        -- 大出血ICD标记
        LEFT JOIN (
            SELECT DISTINCT hadm_id
            FROM MIMIC_IV.diagnoses_icd
            WHERE (icd_version = 10 AND icd_code = 'R571')
               OR (icd_version = 10 AND icd_code LIKE 'T794%') -- 由‘=’修改为‘LIKE’
               OR (icd_version = 9 AND icd_code = '9584')
               OR (icd_version = 9 AND icd_code = '78559')
        ) bleed ON a.hadm_id = bleed.hadm_id

        -- 血制品事件 + 时间窗口
        LEFT JOIN (
            SELECT ie.stay_id, ie.starttime
            FROM MIMIC_IV.inputevents ie
            INNER JOIN MIMIC_IV.d_items di ON ie.itemid = di.itemid
            WHERE UPPER(di.label) REGEXP 'PACKED RED|RED BLOOD CELL|WHOLE BLOOD|FRESH FROZEN PLASMA|PLATELET|CRYOPRECIPITATE'
        ) bp
            ON a.stay_id = bp.stay_id
            AND bp.starttime >= DATE_SUB(a.trajectory_start_time, INTERVAL 6 HOUR)
            AND bp.starttime < DATE_ADD(a.trajectory_start_time, INTERVAL 6 HOUR)

        GROUP BY a.stay_id, a.hadm_id, a.trajectory_start_time, has_major_bleed
    ) sub
    WHERE sub.has_major_bleed = 1 AND sub.bp_count_12h >= 2
);

-- 统计剔除数量：step3_n = 28,818   step4_n = 28,667;   diff_n=151
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_CMO_step3) AS step3_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Bleeding_step4) AS step4_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_CMO_step3)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Bleeding_step4) AS diff_n;




-- Step5 剔除非脓毒性竞争性休克
-- 剔除逻辑： 场景 1：心源性休克诊断，并且时间窗口内存在 MCS 或 CPR → 剔除
--           场景 2：心脏骤停诊断，并且时间窗口内存在 CPR → 剔除
-- DROP TABLE IF EXISTS Exclusion.tmp_mcs_cpr_proxy;
CREATE TABLE Exclusion.tmp_mcs_cpr_proxy AS
SELECT
    ce.stay_id,
    MAX(CASE
        WHEN UPPER(COALESCE(di.label, '')) REGEXP 'VA ECMO|V-A ECMO|ECMO FLOW|EXTRACORPOREAL MEMBRANE|IABP|INTRA[- ]AORTIC BALLOON|IMPELLA'
        AND UPPER(TRIM(COALESCE(ce.value, ''))) NOT REGEXP '^(OFF|NO|NONE|0|0[.]0|DISCONTINUED|REMOVED)$'
        THEN 1 ELSE 0
    END) AS procedure_mcs_t0_proxy,
    MAX(CASE
        WHEN UPPER(COALESCE(di.label, '')) REGEXP 'CARDIOPULMONARY RESUSCITATION|CPR'
        AND UPPER(TRIM(COALESCE(ce.value, ''))) NOT REGEXP '^(OFF|NO|NONE|0|0[.]0|DISCONTINUED|REMOVED)$'
        THEN 1 ELSE 0
    END) AS procedure_cpr_t0_proxy
FROM MIMIC_IV.chartevents ce
INNER JOIN Exclusion.cohort_Bleeding_step4 b ON ce.stay_id = b.stay_id
LEFT JOIN MIMIC_IV.d_items di ON di.itemid = ce.itemid
-- 严格沿用你图上【非对称窗口：T0-12h ~ T0+6h】
WHERE ce.charttime >= DATE_SUB(b.trajectory_start_time, INTERVAL 12 HOUR)
  AND ce.charttime < DATE_ADD(b.trajectory_start_time, INTERVAL 6 HOUR)
GROUP BY ce.stay_id;
CREATE INDEX idx_tmp_mcs_cpr_stayid ON Exclusion.tmp_mcs_cpr_proxy(stay_id);



-- DROP TABLE IF EXISTS Exclusion.cohort_competing_shock_step5;
CREATE TABLE Exclusion.cohort_competing_shock_step5 AS
SELECT DISTINCT a.*
FROM Exclusion.cohort_Bleeding_step4 a
LEFT JOIN (
    SELECT DISTINCT hadm_id,
        -- 二分法标记cardiogenic_shock
        MAX(CASE WHEN 
                 (x.icd_version = 10 AND x.icd_code = 'R570') 
                 OR (x.icd_version = 9 AND x.icd_code = '78551') 
        THEN 1 ELSE 0 END) 
        AS dx_cardiogenic_shock_index,
        -- 二分法标记cardiac_arrest
        MAX(CASE WHEN 
                 (x.icd_version = 10 AND x.icd_code LIKE 'I46%') 
                 OR (x.icd_version = 9 AND x.icd_code IN ('4275', '42741', '42742')) 
        THEN 1 ELSE 0 END)
        AS dx_cardiac_arrest_index
    FROM MIMIC_IV.diagnoses_icd x
    GROUP BY x.hadm_id
) dx ON a.hadm_id = dx.hadm_id
LEFT JOIN Exclusion.tmp_mcs_cpr_proxy pr ON a.stay_id = pr.stay_id
-- 1. 场景 1：心源性休克诊断，并且时间窗口内存在 MCS 或 CPR → 剔除
-- 2. 场景 2：心脏骤停诊断，并且时间窗口内存在 CPR → 剔除
WHERE NOT (
    (COALESCE(dx.dx_cardiogenic_shock_index, 0) = 1
     AND (COALESCE(pr.procedure_mcs_t0_proxy,0)=1 OR COALESCE(pr.procedure_cpr_t0_proxy,0)=1))
    OR
    (COALESCE(dx.dx_cardiac_arrest_index,0)=1
     AND COALESCE(pr.procedure_cpr_t0_proxy,0)=1)
);

-- 统计: step4_n = 28,667;   step5_n = 28,413;   diff_n=254
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Bleeding_step4) AS step4_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_competing_shock_step5) AS step5_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Bleeding_step4) 
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_competing_shock_step5) AS diff_n;




-- Step6: 剔除 Cardiac surgery before&at T0
-- DROP TABLE IF EXISTS Exclusion.cohort_Cardiac_Surgery_step6;
CREATE TABLE Exclusion.cohort_Cardiac_Surgery_step6 AS
SELECT a.*
FROM Exclusion.cohort_competing_shock_step5 a
LEFT JOIN (
    SELECT DISTINCT pc.hadm_id, pc.chartdate
    FROM MIMIC_hosp.procedures_icd pc
    -- 关联T0时刻锁定的service、careunit
    LEFT JOIN tmp_sv_t0_global sv ON pc.hadm_id = sv.hadm_id
    LEFT JOIN tmp_tf_t0_global tf ON pc.hadm_id = tf.hadm_id
     WHERE (
        (pc.icd_version = 10 AND UPPER(REPLACE(REPLACE(TRIM(pc.icd_code), '.', ''), ' ', '')) IN(
            '0210089','0210093','0210099','021009W','02100A3','02100A8',
            '02100A9','02100AW','02100Z3','02100Z8','02100Z9',
            '0211093','0211099','021109W','02110A9','02110AW',
            '02110Z3','02110Z8','02110Z9',
            '0212093','0212099','021209W','02120AW','02120Z8','02120Z9',
            '0213093','0213099','021309W','02130A3','02130Z8',
            '02QF0ZZ','02QG0ZZ',
            '02RF08Z','02RF0JZ','02RF0KZ',
            '02RG08Z','02RG0JZ','02RG0KZ',
            '02RJ08Z','02RW0JZ','02RX08Z','02RX0JZ'
        ))
        OR (pc.icd_version = 9 AND UPPER(REPLACE(REPLACE(TRIM(pc.icd_code), '.', ''), ' ', '')) IN(
            '3511','3512','3514','3521','3522','3523','3524','3527',
            '3611','3612','3613','3614','3615','3616','3619','3845'
        ))
    )
    AND (sv.curr_service = 'CSURG' OR tf.careunit IN ('Cardiac Vascular Intensive Care Unit (CVICU)','PACU'))
) cs ON a.hadm_id = cs.hadm_id
AND cs.chartdate <= DATE(a.trajectory_start_time)
WHERE cs.hadm_id IS NULL; -- 保留没有匹配到术前心脏手术的患者


-- 统计结果：step5_n = 28,413;   step6_n=24,265;   diff_n=4,148
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_competing_shock_step5) AS step5_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Cardiac_Surgery_step6) AS step6_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_competing_shock_step5)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Cardiac_Surgery_step6) AS diff_n;



-- Step7: 剔除 Major Surgery before&at T0  
-- procedures_icd.chartdate <= DATE(t0)
-- DROP TABLE IF EXISTS Exclusion.cohort_Major_Surgery_step7;
CREATE TABLE Exclusion.cohort_Major_Surgery_step7 AS
SELECT a.*
FROM Exclusion.cohort_Cardiac_Surgery_step6 a
LEFT JOIN (
    SELECT DISTINCT pc.hadm_id, pc.chartdate FROM MIMIC_hosp.procedures_icd pc
    LEFT JOIN tmp_sv_t0_global sv ON pc.hadm_id = sv.hadm_id
    LEFT JOIN tmp_tf_t0_global tf ON pc.hadm_id = tf.hadm_id
    WHERE (
           -- 条件1：icd_code属于major surgery
           ((icd_version = 10 AND icd_code IN ('0FY00Z0','0FY00Z1','0TY00Z0','0TY10Z0'))
           OR (icd_version = 9 AND icd_code IN ('5411','5412','5419','3402','3403',
                                                '0124','0123','5059','5051','5569')))
           -- 条件2：科室符合 OR ICU单元符合                                    
           AND (sv.curr_service IN ('SURG','NSURG','TRAUM','VSURG','TSURG','ORTHO','PSURG')
                OR tf.careunit IN ('Surgical Intensive Care Unit (SICU)',
                                     'Trauma SICU (TSICU)',
                                     'Neuro Surgical Intensive Care Unit (Neuro SICU)',
                                     'PACU', 'Surgery/Vascular/Intermediate'))
          )
) maj ON a.hadm_id = maj.hadm_id
AND maj.chartdate <= DATE (a.trajectory_start_time)
WHERE maj.hadm_id IS NULL;

-- 样本统计: step6_n = 24,265;   step7_n = 23,854;   diff_n=411
SELECT
  (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Cardiac_Surgery_step6) AS step6_n,
  (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Major_Surgery_step7) AS step7_n,
  (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Cardiac_Surgery_step6)
  - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Major_Surgery_step7) AS diff_n;



-- Step8: 剔除 CPR&Cardiac arrest before&on T0 day
--   DATE(procedures.chartdate) <= DATE(t0)
-- DROP TABLE IF EXISTS Exclusion.cohort_CPR_step8;
CREATE TABLE Exclusion.cohort_CPR_step8 AS
SELECT a.*
FROM Exclusion.cohort_Major_Surgery_step7 a
LEFT JOIN (
    SELECT DISTINCT pcd.hadm_id, pcd.chartdate FROM MIMIC_hosp.procedures_icd pcd
    LEFT JOIN MIMIC_IV.diagnoses_icd dg ON pcd.hadm_id = dg.hadm_id
    WHERE (
          -- 条件1：CPR
          (pcd.icd_version = 9 AND pcd.icd_code = '9960')
          -- 条件2：Cardiac arrest
          AND ((dg.icd_version = 10 AND dg.icd_code LIKE 'I46%')
               OR (dg.icd_version = 9 AND dg.icd_code IN ('4275','42741','42742')))
          )
) cpr ON a.hadm_id = cpr.hadm_id
AND cpr.chartdate <= DATE (a.trajectory_start_time)
WHERE cpr.hadm_id IS NULL;

-- 样本统计step7_n = 23,854;   step8_n = 23,756;   diff_n=98
SELECT
  (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Major_Surgery_step7) AS step7_n,
  (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_CPR_step8) AS step8_n,
  (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Major_Surgery_step7)
  - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_CPR_step8) AS diff_n;




-- Step9: 剔除 Obstructive-shock before&at T0 
-- DROP TABLE IF EXISTS Exclusion.cohort_Obstructive_step9;
CREATE TABLE Exclusion.cohort_Obstructive_step9 AS
SELECT a.*
FROM Exclusion.cohort_CPR_step8 a
LEFT JOIN (
    SELECT DISTINCT dg.hadm_id, pc.chartdate
    FROM MIMIC_hosp.procedures_icd pc
    LEFT JOIN MIMIC_IV.diagnoses_icd dg ON dg.hadm_id = pc.hadm_id
    WHERE(
          -- 条件1：pericardiocentesis
          (pc.icd_version = 9 AND pc.icd_code = '370') 
          -- 条件2：obstructive_shock_cause
          AND (
               (dg.icd_version = 10 AND dg.icd_code LIKE 'I26%')
               OR (dg.icd_version = 10 AND dg.icd_code = 'I314')
               OR (dg.icd_version = 10 AND dg.icd_code LIKE 'J930%')
               OR (dg.icd_version = 9 AND dg.icd_code LIKE '4151%')
               OR (dg.icd_version = 9 AND dg.icd_code = '4233')
               OR (dg.icd_version = 9 AND dg.icd_code = '5120')
            )
         )
) obs ON a.hadm_id = obs.hadm_id
AND obs.chartdate <= DATE(a.trajectory_start_time) 
WHERE obs.hadm_id IS NULL;

-- 统计结果: step8_n=23,756   step9_n=23,704 diff_n=52
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_CPR_step8) AS step8_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Obstructive_step9) AS step9_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_CPR_step8)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Obstructive_step9) AS diff_n;



-- Step10: 剔除 Neurogenic-shock before&at T0 
-- diagnoses_icd 无时间戳, 按住院期间存在即剔除
-- 剔除规则：有急性脊髓损伤 + 脊柱减压手术，并且【科室符合 OR ICU单元符合】*
-- DROP TABLE IF EXISTS Exclusion.cohort_Neurogenic_step10;
CREATE TABLE Exclusion.cohort_Neurogenic_step10 AS
SELECT a.*
FROM Exclusion.cohort_Obstructive_step9 a
LEFT JOIN (
    -- 一次性合并：脊髓损伤诊断 + service科室 + transfer单元
    SELECT DISTINCT dg.hadm_id, pc.chartdate
    FROM MIMIC_IV.diagnoses_icd dg
    -- 关联procedures_icd
    LEFT JOIN MIMIC_hosp.procedures_icd pc ON dg.hadm_id = pc.hadm_id
    -- 关联services科室
    LEFT JOIN tmp_sv_t0_global sv ON dg.hadm_id = sv.hadm_id
    LEFT JOIN tmp_tf_t0_global tf ON dg.hadm_id = tf.hadm_id
    WHERE (
           -- 条件1：急性脊髓损伤ICD编码
           ((dg.icd_version = 10 AND dg.icd_code REGEXP '^(S14|S24|S34)')
           OR (dg.icd_version = 9 AND dg.icd_code REGEXP '^(806|952)'))
           -- 条件2：脊柱减压手术
           AND (pc.icd_version = 9 AND pc.icd_code = 0309 )
           -- 条件3：科室匹配 OR ICU单元匹配
           AND (sv.curr_service IN ('NSURG','ORTHO','TRAUM')
             OR tf.careunit IN ('Neuro Surgical Intensive Care Unit (Neuro SICU)',
                                'Trauma SICU (TSICU)'))
    )
) neuro_obs ON a.hadm_id = neuro_obs.hadm_id
AND neuro_obs.chartdate <= DATE(a.trajectory_start_time)
WHERE neuro_obs.hadm_id IS NULL;
-- 统计结果：step9_n=23,704 ;   step10_n =23,693;   diff_n=11
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Obstructive_step9) AS step9_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Neurogenic_step10) AS step10_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Obstructive_step9)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Neurogenic_step10) AS diff_n;



-- Step11: 剔除 MCS initiated at/after T0  
-- 剔除条件： 满足以下任一一个条件，则剔除
-- 条件A：同时存在ECMO_in & Ecmo_out
-- 条件B：IABP在使用 & 满足cardiogenic_shock/curr_service='CSURG'/careunit in CVICU or CCU这三个条件中的任意一个
-- 条件C：IMPELLA在使用 & 满足cardiogenic_shock/curr_service='CSURG'/careunit in CVICU or CCU这三个条件中的任意一个
-- 处理逻辑：
-- ①建立一张汇总包含ECMO_in, ECMO_out, IABP, IMPELLA, cardiogenic_shock信息的表，均用bool值表示发生/未发生（T0时和TO后）
-- ②cohort_MCS_step12和汇总表 合并，编写条件，进行剔除

-- ① MCS 事件集（itemid 映射对齐 08）
-- DROP TABLE IF EXISTS Exclusion.tmp_mcs_events;
CREATE TABLE Exclusion.tmp_mcs_events AS
SELECT pe.stay_id, pe.starttime, pe.endtime, m.subtype
FROM MIMIC_icu.procedureevents pe
JOIN (
    SELECT 224272 AS itemid, 'iabp'    AS subtype
    UNION ALL SELECT 228169, 'impella'
    UNION ALL SELECT 229529, 'ecmo_in'
    UNION ALL SELECT 229530, 'ecmo_out'
) m ON m.itemid = pe.itemid
WHERE pe.stay_id IN (SELECT stay_id FROM Exclusion.cohort_Neurogenic_step10);
CREATE INDEX idx_tmp_mcs_stay ON Exclusion.tmp_mcs_events(stay_id, subtype, starttime);

-- ② 配对 ECMO：T0 时双路在用，或 T0 后出现时间重叠的 in/out 配对（对齐 08 的配对重叠判定）
-- DROP TABLE IF EXISTS Exclusion.tmp_ecmo_paired;
CREATE TABLE Exclusion.tmp_ecmo_paired AS
SELECT DISTINCT b.stay_id
FROM Exclusion.cohort_Neurogenic_step10 b
JOIN Exclusion.tmp_mcs_events inf
  ON inf.stay_id = b.stay_id AND inf.subtype = 'ecmo_in'
JOIN Exclusion.tmp_mcs_events outf
  ON outf.stay_id = b.stay_id AND outf.subtype = 'ecmo_out'
WHERE
    -- 场景A：T0 时两路均活跃（开区间：endtime 为空时取 starttime，须 > T0）
    ((inf.starttime <= b.trajectory_start_time
      AND IFNULL(inf.endtime, inf.starttime) > b.trajectory_start_time)
     AND (outf.starttime <= b.trajectory_start_time
          AND IFNULL(outf.endtime, outf.starttime) > b.trajectory_start_time))
    OR
    -- 场景B：T0 后出现时间重叠的配对（重叠区间与 (T0, trajectory_end) 相交，
    --        且重叠起点严格 > T0 —— 即"T0 后新开始"）
    (GREATEST(inf.starttime, outf.starttime, b.trajectory_start_time)
     < LEAST(IFNULL(inf.endtime, b.trajectory_end_time),
             IFNULL(outf.endtime, b.trajectory_end_time),
             b.trajectory_end_time)
     AND GREATEST(inf.starttime, outf.starttime, b.trajectory_start_time)
         > b.trajectory_start_time);
CREATE INDEX idx_tmp_ecmo_stay ON Exclusion.tmp_ecmo_paired(stay_id);

-- ③ stay 级汇总（基于 step10 队列；心源性休克编码 R570/78551 取自 06）
-- DROP TABLE IF EXISTS MIMIC_icu.mcs_cardiogenic_shock_summary;
CREATE TABLE MIMIC_icu.mcs_cardiogenic_shock_summary AS
SELECT
    base.stay_id, base.hadm_id,
    -- IABP：T0 时活跃（开区间）或 T0 后新开始（严格 > T0 且 < traj_end）
    MAX(CASE WHEN m.subtype = 'iabp' AND (
        (m.starttime <= base.trajectory_start_time
         AND IFNULL(m.endtime, m.starttime) > base.trajectory_start_time)
        OR (m.starttime > base.trajectory_start_time
            AND m.starttime < base.trajectory_end_time)
    ) THEN 1 ELSE 0 END) AS iabp,
    -- Impella：同上
    MAX(CASE WHEN m.subtype = 'impella' AND (
        (m.starttime <= base.trajectory_start_time
         AND IFNULL(m.endtime, m.starttime) > base.trajectory_start_time)
        OR (m.starttime > base.trajectory_start_time
            AND m.starttime < base.trajectory_end_time)
    ) THEN 1 ELSE 0 END) AS impella,
    -- 心源性休克诊断（编码清单来自 06）
    MAX(IFNULL(cs.cardiogenic_shock, 0)) AS cardiogenic_shock,
    -- 配对 ECMO（T0 时在用 或 T0 后重叠开始）
    MAX(ep.stay_id IS NOT NULL) AS paired_ecmo
FROM Exclusion.cohort_Neurogenic_step10 base
LEFT JOIN Exclusion.tmp_mcs_events m
    ON base.stay_id = m.stay_id
LEFT JOIN Exclusion.tmp_ecmo_paired ep
    ON ep.stay_id = base.stay_id
LEFT JOIN (
    SELECT DISTINCT hadm_id, 1 AS cardiogenic_shock
    FROM MIMIC_IV.diagnoses_icd
    WHERE (icd_version = 9  AND icd_code = '78551')
       OR (icd_version = 10 AND icd_code = 'R570')
) cs ON base.hadm_id = cs.hadm_id
GROUP BY base.stay_id, base.hadm_id;

-- ④ Step11 剔除（join 键改为 stay_id）
-- DROP TABLE IF EXISTS Exclusion.cohort_MCS_step11;
CREATE TABLE Exclusion.cohort_MCS_step11 AS
SELECT a.*
FROM Exclusion.cohort_Neurogenic_step10 a
LEFT JOIN (
    SELECT DISTINCT m.stay_id
    FROM MIMIC_icu.mcs_cardiogenic_shock_summary m
    LEFT JOIN tmp_sv_t0_global sv ON m.hadm_id = sv.hadm_id
    LEFT JOIN tmp_tf_t0_global tf ON m.hadm_id = tf.hadm_id
    WHERE
        -- 条件A：配对 ECMO（T0 时在用 或 T0 后重叠开始）
        m.paired_ecmo = 1
        -- 条件B：IABP（T0 时在用 或 T0 后开始）+ 心源性休克 + (CSURG / CVICU / CCU)
        OR (m.iabp = 1 
            AND (m.cardiogenic_shock = 1
                 OR sv.curr_service = 'CSURG'
                 OR tf.careunit IN ('Cardiac Vascular Intensive Care Unit (CVICU)',
                                    'Coronary Care Unit (CCU)')))
        -- 条件C：Impella 同理
        OR (m.impella = 1
            AND (m.cardiogenic_shock = 1
                 OR sv.curr_service = 'CSURG'
                 OR tf.careunit IN ('Cardiac Vascular Intensive Care Unit (CVICU)',
                                    'Coronary Care Unit (CCU)')))
) mcs ON a.stay_id = mcs.stay_id
WHERE mcs.stay_id IS NULL;

-- 统计结果: step10_n = 23,693  step11_n = 23,459  diff_n = 234
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Neurogenic_step10) AS step10_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_MCS_step11) AS step11_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_Neurogenic_step10)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_MCS_step11) AS diff_n;




-- 正式剔除DNR和DNI之前，建立code_status表
-- 构建cs_classified，对chartevents的code status文本分类
-- DROP TABLE IF EXISTS MIMIC_derived.ce_classified;
CREATE TABLE MIMIC_derived.ce_classified AS
SELECT
    ce.stay_id,
    ce.charttime,
    ce.storetime,
    ce.itemid,
    ce.value,
    -- 分类标签
    CASE
        WHEN UPPER(TRIM(ce.value)) = '' THEN 'unknown'
        -- 舒适护理 / CMO
        WHEN UPPER(TRIM(ce.value)) REGEXP 'COMFORT[[:space:]]*(MEASURES|CARE)?[[:space:]]*(ONLY)?|(^|[^A-Z])CMO([^A-Z]|$)' THEN 'comfort'
        -- 撤除/停止生命支持
        WHEN UPPER(TRIM(ce.value)) REGEXP 'WITHDRAW(AL|N)?|WITHHOLD(ING)?|REMOVE LIFE SUPPORT|STOP LIFE SUPPORT' THEN 'withdrawal'
        -- 不升级 / 有限代码
        WHEN UPPER(TRIM(ce.value)) REGEXP 'NO[[:space:]]+ESCALATION|LIMITED[[:space:]]+CODE|PARTIAL[[:space:]]+CODE|NO[[:space:]]+COMPRESSIONS|NO[[:space:]]+SHOCK' THEN 'no_escalation'
        -- DNR+DNI同时存在
        WHEN UPPER(TRIM(ce.value)) REGEXP '(^|[^A-Z])DNR([^A-Z]|$)|DO[[:space:]]+NOT[[:space:]]+RESUSCITATE'
             AND UPPER(TRIM(ce.value)) REGEXP '(^|[^A-Z])DNI([^A-Z]|$)|DO[[:space:]]+NOT[[:space:]]+INTUBATE' THEN 'dnr_dni'
        -- 仅DNR
        WHEN UPPER(TRIM(ce.value)) REGEXP '(^|[^A-Z])DNR([^A-Z]|$)|DO[[:space:]]+NOT[[:space:]]+RESUSCITATE' THEN 'dnr_only'
        -- 仅DNI
        WHEN UPPER(TRIM(ce.value)) REGEXP '(^|[^A-Z])DNI([^A-Z]|$)|DO[[:space:]]+NOT[[:space:]]+INTUBATE' THEN 'dni_only'
        -- Full Code：全力复苏（含 FULL CODE / FULL RESUSCITATION / FULL SUPPORT 等写法）
        WHEN UPPER(TRIM(ce.value)) REGEXP 'FULL[[:space:]]+CODE|FULL[[:space:]]+RESUSCITATION|FULL[[:space:]]+SUPPORT|RESUSCITATE[[:space:]]*/?[[:space:]]*INTUBATE' THEN 'full_code'
        ELSE 'unknown'
    END AS class,
    -- scope划分：primary(全局) / intubation(插管专项)
    CASE
        WHEN ce.itemid IN (223758, 228687) THEN 'primary'
        WHEN ce.itemid = 229784 THEN 'intubation'
    END AS scope
FROM MIMIC_IV.chartevents ce
WHERE ce.itemid IN (223758, 228687, 229784); -- MIMIC code_status itemid
-- 建立索引
CREATE INDEX idx_ce_stayid ON MIMIC_derived.ce_classified(stay_id);



-- 截断机制（对齐 08）：T0 后、trajectory_end 前首次出现 primary scope 且
-- class 为 comfort / withdrawal 的时间点；该时间点之后的 4h 窗口不再干净
-- DROP TABLE IF EXISTS MIMIC_icu.cs_truncation;
CREATE TABLE MIMIC_icu.cs_truncation AS
SELECT
    p.stay_id,
    MIN(a.charttime) AS first_cmo_or_withdrawal
FROM Exclusion.cohort_input p
INNER JOIN MIMIC_derived.ce_classified a
    ON a.stay_id = p.stay_id
   AND a.scope = 'primary'
   AND a.class IN ('comfort', 'withdrawal')
   AND a.charttime >= p.trajectory_start_time
   AND a.charttime <  p.trajectory_end_time
GROUP BY p.stay_id;
CREATE INDEX idx_cs_trunc_stayid ON MIMIC_icu.cs_truncation(stay_id);

-- 建立code_status
-- DROP TABLE IF EXISTS MIMIC_icu.code_status;
CREATE TABLE MIMIC_icu.code_status AS
SELECT
    p.stay_id,
    (SELECT a.class
     FROM MIMIC_derived.ce_classified a
     WHERE a.stay_id = p.stay_id
       AND a.scope = 'primary'
       AND a.class <> 'unknown'
       AND a.charttime < p.trajectory_start_time
     ORDER BY a.charttime DESC, a.storetime DESC, a.itemid DESC
     LIMIT 1) AS latest_primary,
    (SELECT a.class
     FROM MIMIC_derived.ce_classified a
     WHERE a.stay_id = p.stay_id
       AND a.scope = 'intubation'
       AND a.class <> 'unknown'
       AND a.charttime < p.trajectory_start_time
     ORDER BY a.charttime DESC, a.storetime DESC, a.itemid DESC
     LIMIT 1) AS latest_intubation
FROM Exclusion.cohort_input p;
-- 建立索引
CREATE INDEX idx_code_status_stayid ON MIMIC_icu.code_status(stay_id);


-- Step12: 剔除 DNR before T0  
--   code_status status='DNR', charttime < t0
-- DROP TABLE IF EXISTS Exclusion.cohort_DNR_step12;
CREATE TABLE Exclusion.cohort_DNR_step12 AS
SELECT a.*
FROM Exclusion.cohort_MCS_step11 a
LEFT JOIN MIMIC_icu.code_status dnr ON a.stay_id = dnr.stay_id
      AND dnr.latest_primary IN ('dnr_only', 'dnr_dni')
WHERE dnr.stay_id IS NULL;

-- 统计结果； step11_n=23,459;  step12_n=23,059;  diff_n=406
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_MCS_step11) AS step11_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_DNR_step12) AS step12_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_MCS_step11)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_DNR_step12) AS diff_n;



-- Step13: 剔除 DNI before T0  
--   code_status status='DNI', charttime < t0
-- DROP TABLE IF EXISTS Exclusion.cohort_DNI_step13;
CREATE TABLE Exclusion.cohort_DNI_step13 AS
SELECT a.*
FROM Exclusion.cohort_DNR_step12 a
LEFT JOIN MIMIC_icu.code_status dni ON a.stay_id = dni.stay_id
      AND (dni.latest_primary IN ('dni_only','dnr_dni')
           OR dni.latest_intubation IN ('dni_only','dnr_dni'))
WHERE dni.stay_id IS NULL;
-- 统计结果: step12_n = 23,059;   step13_n = 23,047   diff_n=12
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_DNR_step12) AS step12_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_DNI_step13) AS step13_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_DNR_step12)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_DNI_step13) AS diff_n;


-- Step14: 剔除T0后无完整4小时观察窗口
-- DROP TABLE IF EXISTS Exclusion.cohort_4h_window_step14;
CREATE TABLE Exclusion.cohort_4h_window_step14 AS
SELECT a.*
FROM Exclusion.cohort_DNI_step13 a
LEFT JOIN MIMIC_icu.cs_truncation tr
    ON a.stay_id = tr.stay_id
WHERE a.n_complete_4h_windows >= 1
  AND (
        tr.first_cmo_or_withdrawal IS NULL
        OR TIMESTAMPDIFF(SECOND, a.trajectory_start_time, tr.first_cmo_or_withdrawal) >= 14400
      );
-- 统计人数: diff_n=3
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_DNI_step13) AS step13_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_4h_window_step14) AS step14_n,
    (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_DNI_step13)
    - (SELECT COUNT(DISTINCT stay_id) FROM Exclusion.cohort_4h_window_step14) AS diff_n;
