
SET client_encoding TO 'UTF8';
SET search_path TO mimic_derived, public;
\pset pager off
\timing on

\echo '====================================================================='
\echo '开始重建 13 个 CSV（行 = 08 保留 stay/window）'
\echo '====================================================================='


-- =====================================================================
-- A. 两个「直接 = 08 输出表」的文件
-- =====================================================================

-- A1. window_context_4h_v4.csv  ==  context_retained_window（窗口级 RRT 动态 context）
\copy (SELECT subject_id, hadm_id, stay_id, window_index, window_start, window_end, rrt_active, crrt_active, ihd_active, pd_active, rrt_started_in_window, rrt_ended_in_window, rrt_type_in_window, sensitivity_strict_dka_hhs FROM context_retained_window ORDER BY stay_id, window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/window_context_4h_v4.csv' WITH (FORMAT csv, HEADER true)

-- A2. patient_context_flags_v4.csv  ==  context_retained_patient（stay 级 flag）
\copy (SELECT * FROM context_retained_patient ORDER BY stay_id) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/patient_context_flags_v4.csv' WITH (FORMAT csv, HEADER true)


-- =====================================================================
-- B. 8 个「特征表 + hf_chronic/uremia」的窗口级文件
-- =====================================================================

-- B1. body_weight_4h
\copy (SELECT f.*, k.hf_chronic, k.uremia FROM body_weight_4h_first_icu f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index LEFT JOIN clean_window_keys k ON f.stay_id = k.stay_id AND f.window_index = k.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/body_weight_4h_v4_context_complete_clean.csv' WITH (FORMAT csv, HEADER true)

-- B2. fluid_action_4h
\copy (SELECT f.*, k.hf_chronic, k.uremia FROM fluid_action_4h_first_icu f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index LEFT JOIN clean_window_keys k ON f.stay_id = k.stay_id AND f.window_index = k.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/fluid_action_4h_v4_context_complete_clean.csv' WITH (FORMAT csv, HEADER true)

-- B3. lab_state_24h
\copy (SELECT f.*, k.hf_chronic, k.uremia FROM lab_state_24h_first_icu f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index LEFT JOIN clean_window_keys k ON f.stay_id = k.stay_id AND f.window_index = k.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/lab_state_24h_v4_context_complete_clean.csv' WITH (FORMAT csv, HEADER true)

-- B4. sofa_state_4h（该表首列是 stay_id，CSV 亦为 stay_id 打头）
\copy (SELECT f.*, k.hf_chronic, k.uremia FROM sofa_state_4h_first_icu f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index LEFT JOIN clean_window_keys k ON f.stay_id = k.stay_id AND f.window_index = k.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/sofa_state_4h_v4_context_complete_clean.csv' WITH (FORMAT csv, HEADER true)

-- B5. vital_state_4h
\copy (SELECT f.*, k.hf_chronic, k.uremia FROM vital_state_4h_first_icu f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index LEFT JOIN clean_window_keys k ON f.stay_id = k.stay_id AND f.window_index = k.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/vital_state_4h_v4_context_complete_clean.csv' WITH (FORMAT csv, HEADER true)

-- B6. urine_state_4h（尾部有 2 个 R 侧离群值列，PG 未实现 -> NULL）
\copy (SELECT f.*, k.hf_chronic, k.uremia, NULL::smallint AS urine_outlier_4h_flag, NULL::smallint AS urine_outlier_24h_flag FROM urine_state_4h_first_icu f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index LEFT JOIN clean_window_keys k ON f.stay_id = k.stay_id AND f.window_index = k.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/urine_state_4h_v4_context_complete_clean_outlier_handled.csv' WITH (FORMAT csv, HEADER true)

-- B7. treatment_action_4h（corrected，NEE 重建列按 CSV 顺序显式排列）
\copy (SELECT f.subject_id, f.hadm_id, f.stay_id, f.window_index, f.window_start, f.window_end, f.total_fluid_ml, f.crystalloid_ml, f.saline_ml, f.balanced_crystalloid_ml, f.albumin_ml, f.albumin_5_ml, f.albumin_25_ml, f.fluid_record_count, f.fluid_any, f.norepinephrine_twa_mcg_kg_min, f.epinephrine_twa_mcg_kg_min, f.phenylephrine_twa_mcg_kg_min, f.dopamine_twa_mcg_kg_min, f.vasopressin_twa_units_min, f.nee_twa_mcg_kg_min, f.nee_max_mcg_kg_min, f.nee_max_original_mcg_kg_min, f.nee_max_rebuild_applied, f.nee_max_rebuild_note, f.vasopressor_event_overlap_minutes, f.vasopressor_record_count, f.vasopressor_any, f.any_treatment_action, f.hf_chronic, f.uremia FROM treatment_action_4h_corrected f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/treatment_action_4h_latest_clean_corrected_v4_context_complete.csv' WITH (FORMAT csv, HEADER true)

-- B8. vasopressor_action_4h（corrected，同上显式排列）
\copy (SELECT f.subject_id, f.hadm_id, f.stay_id, f.window_index, f.window_start, f.window_end, f.norepinephrine_twa_mcg_kg_min, f.epinephrine_twa_mcg_kg_min, f.phenylephrine_twa_mcg_kg_min, f.dopamine_twa_mcg_kg_min, f.vasopressin_twa_units_min, f.nee_twa_mcg_kg_min, f.nee_max_mcg_kg_min, f.nee_max_original_mcg_kg_min, f.nee_max_rebuild_applied, f.nee_max_rebuild_note, f.vasopressor_event_overlap_minutes, f.vasopressor_record_count, f.vasopressor_any, f.hf_chronic, f.uremia FROM vasopressor_action_4h_corrected f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/vasopressor_action_4h_latest_clean_corrected_v4_context_complete.csv' WITH (FORMAT csv, HEADER true)


-- =====================================================================
-- C. 2 个「特征表 + context 列 + flag」的窗口级 flagged 文件
-- =====================================================================

-- C1. state_4h_wide（首列 stay_id；尾部 = 特征 + hf/uremia + 离群值 + context 列）
\copy (SELECT f.*, k.hf_chronic, k.uremia, NULL::smallint AS urine_urine_outlier_4h_flag, NULL::smallint AS urine_urine_outlier_24h_flag, p.final_trajectory_end AS trajectory_end_context_v4, p.final_n_windows AS n_4h_windows_context_v4, CASE WHEN w.first_context_truncation_time IS NOT NULL THEN 1 ELSE 0 END AS trajectory_truncated_context_v4, w.final_context_handling, w.first_context_truncation_time, w.first_context_truncation_reason, p.final_n_windows, p.final_trajectory_end, p.flag_chronic_hf, p.flag_esrd_or_chronic_dialysis, p.flag_ckd_non_esrd, p.flag_pulmonary_edema_or_fluid_overload, p.flag_cirrhosis_portal_htn_ascites, p.flag_pulmonary_htn_or_right_hf, p.flag_immunocompromised, p.flag_copd_or_chronic_lung, p.flag_single_window_trajectory, p.first_careunit, p.last_careunit, p.flag_full_code_before_t0_structured, p.flag_ever_rrt_in_trajectory, p.flag_ever_crrt_in_trajectory, p.flag_ever_ihd_in_trajectory, p.flag_ever_pd_in_trajectory, p.sensitivity_strict_dka, p.sensitivity_strict_hhs, p.sensitivity_strict_dka_hhs, 1 AS done_context_v4, rw.rrt_active, rw.crrt_active, rw.ihd_active, rw.pd_active, rw.rrt_started_in_window, rw.rrt_ended_in_window, rw.rrt_type_in_window FROM state_4h_wide_first_icu f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index LEFT JOIN clean_window_keys k ON f.stay_id = k.stay_id AND f.window_index = k.window_index LEFT JOIN context_retained_patient p ON f.stay_id = p.stay_id LEFT JOIN context_retained_window rw ON f.stay_id = rw.stay_id AND f.window_index = rw.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/state_4h_wide_v4_context_complete_clean_outlier_handled_flagged.csv' WITH (FORMAT csv, HEADER true)

-- C2. trajectory_4h（source_file 为 R 溯源列 -> NULL）
\copy (SELECT f.subject_id, f.hadm_id, f.stay_id, f.window_index, f.window_start, f.window_end, f.raw_sepsis_onset_time, f.suspected_infection_time, f.trajectory_start_time, f.trajectory_end_time, f.onset_before_icu, f.onset_hour_from_icu, f.onset_sofa2_score, f.baseline_sofa2, f.delta_sofa2, f.brain, f.respiratory, f.cardiovascular, f.liver, f.kidney, f.hemostasis, NULL::text AS source_file, k.hf_chronic, k.uremia, p.final_trajectory_end AS trajectory_end_context_v4, p.final_n_windows AS n_4h_windows_context_v4, CASE WHEN w.first_context_truncation_time IS NOT NULL THEN 1 ELSE 0 END AS trajectory_truncated_context_v4, w.final_context_handling, w.first_context_truncation_time, w.first_context_truncation_reason, p.final_n_windows, p.final_trajectory_end, p.flag_chronic_hf, p.flag_esrd_or_chronic_dialysis, p.flag_ckd_non_esrd, p.flag_pulmonary_edema_or_fluid_overload, p.flag_cirrhosis_portal_htn_ascites, p.flag_pulmonary_htn_or_right_hf, p.flag_immunocompromised, p.flag_copd_or_chronic_lung, p.flag_single_window_trajectory, p.first_careunit, p.last_careunit, p.flag_full_code_before_t0_structured, p.flag_ever_rrt_in_trajectory, p.flag_ever_crrt_in_trajectory, p.flag_ever_ihd_in_trajectory, p.flag_ever_pd_in_trajectory, p.sensitivity_strict_dka, p.sensitivity_strict_hhs, p.sensitivity_strict_dka_hhs, 1 AS done_context_v4, rw.rrt_active, rw.crrt_active, rw.ihd_active, rw.pd_active, rw.rrt_started_in_window, rw.rrt_ended_in_window, rw.rrt_type_in_window FROM trajectory_4h_first_icu f JOIN context_final_window_keys w ON f.stay_id = w.stay_id AND f.window_index = w.window_index LEFT JOIN clean_window_keys k ON f.stay_id = k.stay_id AND f.window_index = k.window_index LEFT JOIN context_retained_patient p ON f.stay_id = p.stay_id LEFT JOIN context_retained_window rw ON f.stay_id = rw.stay_id AND f.window_index = rw.window_index ORDER BY f.stay_id, f.window_index) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/trajectory_4h_v4_context_complete_clean_flagged.csv' WITH (FORMAT csv, HEADER true)


-- =====================================================================
-- D. 1 个「stay 级 + context 列 + flag」的静态 flagged 文件
-- =====================================================================

-- D1. sepsis3_cohort_final（source_file / loaded_at 为 R 溯源列 -> NULL）
\copy (SELECT c.*, NULL::text AS source_file, NULL::text AS loaded_at, k.hf_chronic, k.uremia, p.final_trajectory_end AS trajectory_end_context_v4, p.final_n_windows AS n_4h_windows_context_v4, CASE WHEN s.first_context_truncation_time IS NOT NULL THEN 1 ELSE 0 END AS trajectory_truncated_context_v4, p.final_context_handling, s.first_context_truncation_time, s.first_context_truncation_reason, p.final_n_windows, p.final_trajectory_end, p.flag_chronic_hf, p.flag_esrd_or_chronic_dialysis, p.flag_ckd_non_esrd, p.flag_pulmonary_edema_or_fluid_overload, p.flag_cirrhosis_portal_htn_ascites, p.flag_pulmonary_htn_or_right_hf, p.flag_immunocompromised, p.flag_copd_or_chronic_lung, p.flag_single_window_trajectory, p.flag_full_code_before_t0_structured, p.flag_ever_rrt_in_trajectory, p.flag_ever_crrt_in_trajectory, p.flag_ever_ihd_in_trajectory, p.flag_ever_pd_in_trajectory, p.sensitivity_strict_dka, p.sensitivity_strict_hhs, p.sensitivity_strict_dka_hhs FROM sepsis3_cohort_final_first_icu c JOIN context_retained_patient p ON c.stay_id = p.stay_id LEFT JOIN context_final_stay_decision s ON c.stay_id = s.stay_id LEFT JOIN (SELECT DISTINCT stay_id, hf_chronic, uremia FROM clean_window_keys) k ON c.stay_id = k.stay_id ORDER BY c.stay_id) TO 'D:/SURF_Sepsis_modeling_handoff_context_complete_v4_20260810/01_core_modeling_data/sepsis3_cohort_final_v4_context_complete_clean_flagged.csv' WITH (FORMAT csv, HEADER true)


-- =====================================================================
-- 校验：各表行数应与 08 汇总一致（窗口 721408 / stay 23044）
-- =====================================================================
SELECT
    (SELECT COUNT(*) FROM context_final_window_keys) AS n_eligible_windows,
    (SELECT COUNT(*) FROM context_retained_patient)  AS n_eligible_stays;

\echo '====================================================================='
\echo '重建完成。请核对上述窗口数/stay 数与 08 输出一致。'
\echo '====================================================================='
