#====================================================================
# MIMIC-IV 脓毒症 4小时时间窗口 48维特征构建流水线
# 流程:
# Step1: 合并预处理好的时序窗口表
# Step2: 匹配MIMIC-IV derived衍生表
# Step3: 计算衍生指标：休克指数、PF比值（含SpO2/FiO2替补方案）、Elixhauser评分
# Step4: 构建机械通气标记、动脉血气标记
# Step5: 筛选最终48维特征，导出数据集
# Step6: 生成各变量缺失率统计表


# ===================== 【配置区】 =====================
# 预处理窗口数据文件夹路径
path_context <- "./01_core_modeling_data"
# MIMIC-IV derived 衍生csv文件夹路径
path_derived <- "./mimiciv_derived"
# 输出文件夹
out_dir <- "./output"

pkgs <- c("data.table", "comorbidity")
if (!all(pkgs %in% rownames(installed.packages()))) {
  install.packages(pkgs[!pkgs %in% rownames(installed.packages())])
}

lapply(pkgs, library, character.only = TRUE)
library(data.table)
library(comorbidity)
# 创建输出文件夹（不存在则新建）
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

# 所有待合并的时序窗口文件 
file_list <- c(
  "body_weight_4h_clean.csv",
  "fluid_action_4h_clean.csv",
  "lab_state_24h_clean.csv",
  "sofa_state_4h_clean.csv",
  "state_4h_clean_outlier_handled_flagged.csv",
  "trajectory_4h_clean_flagged.csv",
  "treatment_action_4h_clean.csv",
  "urine_state_4h_clean_outlier_handled.csv",
  "vasopressor_action_4h_clean.csv",
  "vital_state_4h_clean.csv",
  "window_context_4h.csv"
)
file_path_list <- file.path(path_context, file_list)
# 匹配主键：用来对齐同一个患者、同一个ICU、同一个4h窗口
match_key <- c("subject_id", "hadm_id", "stay_id", "window_index")



# ===================== Step1: 合并预处理好的时序窗口表 =====================
# 读取第一张表作为基准底板
merged_dt <- fread(file_path_list[1])
base_cols <- names(merged_dt)
# 循环读取剩下所有文件，横向拼接，只增加新特征列
for (f in file_path_list[-1]) {
  tmp_cols <- names(fread(f, nrows = 0))
  extra_cols <- setdiff(tmp_cols, c(base_cols, match_key))
  if (length(extra_cols) == 0) {
    message(paste("跳过文件：", basename(f), "，没有新增特征列"))
    next
  }
  dt <- fread(f, select = c(match_key, extra_cols))
  merged_dt <- merge(merged_dt, dt, by = match_key, all.x = TRUE)
  base_cols <- names(merged_dt)
  rm(dt)
  gc()
}

# 合并静态信息：患者基础标记、脓毒症队列标记
static_flags <- fread(file.path(path_context, "patient_context_flags.csv"))
static_sepsis <- fread(file.path(path_context, "sepsis3_cohort_final_clean_flagged.csv"))
static_all <- merge(static_flags, static_sepsis, by = "stay_id", all = TRUE)
all_data <- merge(merged_dt, static_all, by = "stay_id", all.x = TRUE)
setDT(all_data)
message("【Step1完成】合并静态信息后数据集维度：", nrow(all_data), "行 ", ncol(all_data), "列")



# ===================== Step2: 匹配 MIMIC-IV derived 衍生表 =====================

# 自定义函数：读取derived表，自动兼容 stay_id / icustay_id
load_derived <- function(table_name, value_cols, time_col = "charttime") {
  fp <- file.path(path_derived, paste0(table_name, ".csv"))
  header <- fread(fp, nrows = 0)
  all_names <- names(header)
  id_col <- NULL
  if ("stay_id" %in% all_names) {
    id_col <- "stay_id"
  } else if ("icustay_id" %in% all_names) {
    id_col <- "icustay_id"
  } else {
    stop(paste("表", table_name, "中找不到 stay_id / icustay_id，无法匹配窗口"))
  }
  select_cols <- intersect(c(id_col, time_col, value_cols), all_names)
  if (length(select_cols) < 2) {
    stop(paste("表", table_name, "缺少必要字段"))
  }
  dt <- fread(fp, select = select_cols)
  if (id_col != "stay_id") setnames(dt, id_col, "stay_id")
  dt[, (time_col) := as.POSIXct(get(time_col))]
  return(dt)
}

# 提取窗口匹配主键
windows_key <- unique(all_data[, .(stay_id, window_start, window_end, window_index)])
windows_key_with_subj <- unique(all_data[, .(stay_id, subject_id, window_start, window_end, window_index)])

# gender
patients <- fread(file.path(path_derived, "patients.csv"),
                  select = c("subject_id", "gender"))
setDT(patients)
assert_unique_keys(patients, "subject_id", "patients.csv")
all_data[patients, gender := i.gender, on = "subject_id"]
message("  gender 匹配率: ", round(mean(!is.na(all_data$gender)) * 100, 1), "%")

# 2.1 GCS格拉斯哥昏迷评分
gcs_dt <- load_derived("gcs", "gcs")
gcs_matched <- gcs_dt[windows_key, on = .(stay_id, charttime >= window_start, charttime <= window_end), mult = "first"]
all_data[gcs_matched, gcs := i.gcs, on = .(stay_id, window_index)]

# 2.2 SIRS评分
sirs_dt <- fread(file.path(path_derived, "sirs.csv"), select = c("stay_id", "sirs"))
all_data[sirs_dt, sirs := i.sirs, on = "stay_id"]

# 2.3 PT凝血酶原时间
coag_dt <- fread(file.path(path_derived, "coagulation.csv"), select = c("subject_id", "charttime", "pt"))
coag_dt[, charttime := as.POSIXct(charttime)]
pt_matched <- coag_dt[windows_key_with_subj, on = .(subject_id, charttime >= window_start, charttime <= window_end),
                     .(stay_id, window_index, pt = pt[1]), by = .EACHI]
all_data[pt_matched, pt := i.pt, on = .(stay_id, window_index)]

# 2.4 FiO2吸入氧浓度
fio2_dt <- fread(file.path(path_derived, "ventilator_setting.csv"), select = c("stay_id", "charttime", "fio2"))
fio2_dt[, charttime := as.POSIXct(charttime)]
fio2_matched <- fio2_dt[windows_key, on = .(stay_id, charttime >= window_start, charttime <= window_end),
                        .(stay_id, window_index, fio2 = fio2[1]), by = .EACHI]
all_data[fio2_matched, fio2 := i.fio2, on = .(stay_id, window_index)]

# 2.5 AST / ALT肝酶
enzyme_dt <- fread(file.path(path_derived, "enzyme.csv"), select = c("subject_id", "charttime", "ast", "alt"))
enzyme_dt[, charttime := as.POSIXct(charttime)]
enzyme_matched <- enzyme_dt[windows_key_with_subj, on = .(subject_id, charttime >= window_start, charttime <= window_end),
                            .(stay_id, window_index, ast = ast[1], alt = alt[1]), by = .EACHI]
all_data[enzyme_matched, `:=`(ast = i.ast, alt = i.alt), on = .(stay_id, window_index)]

# 2.6 液体总出量
output_dt <- fread(file.path(path_derived, "outputevents.csv"), select = c("stay_id", "charttime", "value"))
output_dt <- output_dt[!is.na(value) & value > 0]
output_dt[, charttime := as.POSIXct(charttime)]
total_output <- output_dt[windows_key, on = .(stay_id, charttime >= window_start, charttime <= window_end),
                          .(total_fluid_output = sum(value, na.rm = TRUE), window_start = i.window_start, window_end = i.window_end),
                          by = .EACHI]
all_data[total_output, total_fluid_output := i.total_fluid_output, on = .(stay_id, window_start, window_end)]
rm(output_dt, total_output)
gc()

# 2.7 血气原始表
bg_dt <- fread(file.path(path_derived, "bg.csv"), select = c("subject_id", "charttime", "specimen", "pao2fio2ratio", "totalco2"))
bg_dt[, charttime := as.POSIXct(charttime)]

message("【Step2完成】所有derived衍生表匹配完毕")



# ===================== Step3: 计算衍生指标：休克指数、PF 比值（含 SpO2/FiO2 替补方案）、Elixhauser 评分 =====================

# 3.1 休克指数 = 心率 / 收缩压；收缩压<=0时记为NA
all_data[, shock_index := ifelse(vital_sbp > 0, vital_heart_rate / vital_sbp, NA)]

# 3.2 PF比值；缺失时用 SpO2/FiO2 作为替代估算
bg_pf <- bg_dt[trimws(specimen) == "ART." & !is.na(pao2fio2ratio)]
pf_matched <- bg_pf[windows_key_with_subj, on = .(subject_id, charttime >= window_start, charttime <= window_end),
                    .(stay_id = i.stay_id, window_index = i.window_index, pf_ratio = pao2fio2ratio[1]), by = .EACHI, nomatch = 0L]
all_data[pf_matched, pf_ratio := i.pf_ratio, on = .(stay_id, window_index)]
all_data[is.na(pf_ratio) & !is.na(vital_spo2) & !is.na(fio2) & fio2 > 0,
         pf_ratio := (vital_spo2 * 100) / fio2]

# 3.3 血清总CO2
bg_tco2 <- bg_dt[!is.na(totalco2) & totalco2 > 0]
tco2_matched <- bg_tco2[windows_key_with_subj, on = .(subject_id, charttime >= window_start, charttime <= window_end),
                        .(serum_co2 = totalco2[1], stay_id = i.stay_id, window_start = i.window_start, window_end = i.window_end), by = .EACHI]
all_data[tco2_matched, serum_co2 := i.serum_co2, on = .(stay_id, window_start, window_end)]

# 3.4 Elixhauser合并症 van Walraven加权评分
diagnoses_icd <- fread(file.path(path_derived, "diagnoses_icd.csv"), select = c("hadm_id", "icd_version", "icd_code"))
elix_9 <- comorbidity(x = diagnoses_icd[icd_version == 9], id = "hadm_id", code = "icd_code",
                      map = "elixhauser_icd9_quan", assign0 = FALSE)
elix_10 <- comorbidity(x = diagnoses_icd[icd_version == 10], id = "hadm_id", code = "icd_code",
                       map = "elixhauser_icd10_quan", assign0 = FALSE)
elix_combined <- rbind(elix_9, elix_10)
setDT(elix_combined)
elix_combined <- elix_combined[, lapply(.SD, max), by = hadm_id]

# van Walraven权重
vw_weights <- c(
  chf = 7,     carit = 5,    valv = -1,   pcd = 4,      pvd = 2,
  hypunc = 0,  hypc = 0,     para = 7,    ond = 6,      cpd = 3,
  diabunc = 0, diabc = 0,    hypothy = 0, rf = 5,       ld = 11,
  pud = 0,     aids = 0,     lymph = 9,   metacanc = 12, solidtum = 4,
  rheumd = 0,  coag = 3,     obes = -4,   wloss = 6,    fed = 5,
  blane = -2,  dane = -2,    alcohol = 0, drug = -7,    psycho = 0,
  depre = -3
)
comorb_cols <- names(vw_weights)

elix_scores <- elix_combined[, .(hadm_id, elixhauser = rowSums(.SD * vw_weights[comorb_cols])), .SDcols = comorb_cols]
all_data[elix_scores, elixhauser := i.elixhauser, on = "hadm_id"]

message("【Step3完成】休克指数、PF比值、Elixhauser评分计算完成")



# ===================== Step4: 构建机械通气标记、动脉血气标记 =====================

# 4.1 机械通气标记：窗口与通气时间段有重叠=1，否则0
vent_dt <- fread(file.path(path_derived, "ventilation.csv"), select = c("stay_id", "starttime", "endtime"))
vent_dt[, starttime := as.POSIXct(starttime)]
vent_dt[, endtime := as.POSIXct(endtime)]

vent_matched <- vent_dt[windows_key, on = .(stay_id, starttime <= window_end, endtime >= window_start),
                        mult = "first", nomatch = 0L]

all_data[vent_matched, mechanical_ventilation := 1, on = .(stay_id, window_index)]
all_data[is.na(mechanical_ventilation), mechanical_ventilation := 0]

# 4.2 动脉血气标记：窗口内存在动脉血气标本=1，否则0
bg_arterial <- bg_dt[trimws(specimen) == "ART."]
arterial_flag <- bg_arterial[windows_key_with_subj, on = .(subject_id, charttime >= window_start, charttime <= window_end),
                             .(abg_arterial_flag = 1, stay_id = i.stay_id, window_index = i.window_index),
                             by = .EACHI, nomatch = 0L]
all_data[arterial_flag, abg_arterial_flag := 1, on = .(stay_id, window_index)]
all_data[is.na(abg_arterial_flag), abg_arterial_flag := 0]
rm(bg_dt, bg_arterial, arterial_flag, bg_pf, bg_tco2)
gc()

message("【Step4完成】机械通气标记、动脉血气标记构建完成")



# ===================== Step5: 筛选最终 48 维特征，导出数据集 =====================
# 目标48维特征清单
export_cols <- c(
  "subject_id", "stay_id", "window_index", "hadm_id","window_start", "window_end",
  "demo_anchor_age",
  "gender",
  "shock_index",
  "elixhauser",
  "gcs",
  "sirs",
  "sofa_sofa2_total",
  "lab_lactate",
  "lab_bicarbonate",
  "lab_inr",
  "lab_sodium",
  "lab_wbc",
  "serum_co2",
  "lab_creatinine",
  "lab_calcium_ionized",
  "ast",
  "pt",
  "lab_platelet_count",
  "lab_bilirubin_total",
  "lab_albumin",
  "lab_calcium_total",
  "lab_glucose",
  "lab_hemoglobin",
  "lab_ptt",
  "lab_potassium",
  "alt",
  "abg_arterial_flag",
  "lab_bun",
  "lab_chloride",
  "lab_ph",
  "lab_magnesium",
  "vital_dbp",
  "vital_map",
  "vital_resp_rate",
  "vital_spo2",
  "vital_sbp",
  "lab_pco2",
  "lab_po2",
  "fio2",
  "pf_ratio",
  "vital_temperature",
  "weight_weight_kg",
  "vital_heart_rate",
  "total_fluid_output",
  "mechanical_ventilation",
  "urine_urine_output_4h_ml",
  "readmission_30d"
)

# 检查特征是否存在，自动剔除不存在的列
existing_cols <- intersect(export_cols, names(all_data))
missing_cols <- setdiff(export_cols, existing_cols)

# 兼容兜底：找不到elixhauser就替换为elixhauser_vw
if (!"elixhauser" %in% existing_cols && "elixhauser_vw" %in% names(all_data)) {
  message("【提示】找不到 elixhauser，将替换为 elixhauser_vw")
  export_cols[export_cols == "elixhauser"] <- "elixhauser_vw"
  existing_cols <- intersect(export_cols, names(all_data))
  missing_cols <- setdiff(export_cols, existing_cols)
}

if (length(missing_cols) > 0) {
  cat("【警告】下面这些目标特征缺失，导出时跳过：", paste(missing_cols, collapse = ", "), "\n")
}
final_data <- all_data[, ..existing_cols]
fwrite(final_data, file.path(out_dir, "48dim_data.csv"), row.names = FALSE)

cat("【Step5完成】数据集导出完成：", file.path(out_dir, "48dim_data.csv"),
    "共", nrow(final_data), "行，", ncol(final_data), "列\n")



# ===================== Step6: 生成各变量缺失率统计表 =====================

setDT(final_data)
na_count <- sapply(final_data, function(x) sum(is.na(x)))
na_pct <- round(na_count / nrow(final_data) * 100, 2)

na_summary <- data.table(
  column = names(final_data),
  missing_count = na_count,
  missing_pct = na_pct
)

setorder(na_summary, -missing_pct)

cat("\n===== 缺失率统计表 =====\n")
print(na_summary)
fwrite(na_summary, file.path(out_dir, "missing_summary.csv"))
cat("\n【Step6完成】缺失统计文件导出完成：", file.path(out_dir, "missing_summary.csv"), "\n")
