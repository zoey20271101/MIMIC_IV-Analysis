### 正式填补前 ###
## 输入文件：48dim_data_version3.csv
## 操作步骤：
# 1.剔除整体有效率 < 20% 的特征列
# 2.剔除患者————vital+sofa_2 < 20%
# 3.标记低乳酸覆盖患者————lactate < 20%，
# “main”为开头的csv文件中保留低乳酸覆盖患者；“drop_lactate_low"为开头的csv文件中剔除低乳酸覆盖患者。
## 中间输出文件：main_45dim.csv; drop_lactate_low_45dim.csv
import pandas as pd
import numpy as np

df = pd.read_csv("48dim_data.csv")
id_cols = ['subject_id', 'stay_id', 'window_index', 'hadm_id', 'window_start', 'window_end']
feature_cols = df.drop(columns = id_cols).columns
vital_cols = [c for c in df.columns if c.startswith('vital_')]
lab_cols = [c for c in df.columns if c.startswith('lab_') and c != 'lab_lactate']
core_keep_for_filter = vital_cols + ['sofa_sofa2_total']
core_keep = core_keep_for_filter + ['lab_lactate']
print(f"number of original columns: {len(feature_cols)}")

#1.剔除整体有效率 < 20% 的特征列
valid_ratio_cols = df[feature_cols].notna().mean() * 100
low_valid_cols = valid_ratio_cols[valid_ratio_cols < 20].index.tolist()
drop_cols = [c for c in low_valid_cols if c not in core_keep]
df = df.drop(columns = drop_cols)
print(f"number of dropped columns: {len(drop_cols)}")
print(f"number of new columns: {len(feature_cols) - len(drop_cols)}")
#2.剔除患者————vital+sofa_2 < 20%
#3.标记低乳酸覆盖患者
drop_stay_id = []
lactate_low_stay_id = []
for stay_id, patient_df in df.groupby("stay_id"):
    core_valid_ratio = patient_df[core_keep_for_filter].notna().mean()
    if (core_valid_ratio < 0.2).any():
        drop_stay_id.append(stay_id)
    if patient_df["lab_lactate"].notna().mean() < 0.2:
        lactate_low_stay_id.append(stay_id)

df['flag_lactate_low'] = 0
df.loc[df['stay_id'].isin(lactate_low_stay_id), 'flag_lactate_low'] = 1
df_filtered = df[~df["stay_id"].isin(drop_stay_id)].copy()
df_drop_lactate_low = df_filtered[~df_filtered["stay_id"].isin(lactate_low_stay_id)].copy()
#统计
print(f"原始窗口总行数 : {len(df)}")
print(f"原始stay患者数量 : {df['stay_id'].nunique()}")
print(f"被剔除患者数量 : {len(drop_stay_id)}")
print(f"过滤后窗口总行数 : {len(df_filtered)}")
print(f"过滤后stay患者数量 : {df_filtered['stay_id'].nunique()}")
print(f"低乳酸覆盖stay数量 : {len(lactate_low_stay_id)}")
print(f"剔除低乳酸后窗口总行数 : {len(df_drop_lactate_low)}")
print(f"剔除低乳酸后stay患者数量 : {df_drop_lactate_low['stay_id'].nunique()}")
df_filtered.to_csv("main_45dim.csv", index=False)
df_drop_lactate_low.to_csv("drop_lactate_low_45dim.csv", index=False)

### 数据填补策略 ###
## 输入文件： main_45dim.csv; drop_lactate_low_45dim.csv
## 输出文件： main_45dim_24h.csv; main_45dim_48h.csv; main_45dim_revised.csv
##          drop_lactate_low_45dim_24h.csv; drop_lactate_low_45dim_48h.csv; drop_lactate_low_45dim_revised.csv
df_1 = pd.read_csv("main_45dim.csv")
df_2 = pd.read_csv("drop_lactate_low_45dim.csv")
WINDOW_HOURS = 4
MAX_GAP_24H = 6
MAX_GAP_48H = 12

# 1.vital:患者内线性插值(双向)
def fill_vital(df_input):
    out = []
    for stay_id, patient in df_input.groupby("stay_id"):
        tmp = patient.copy()
        tmp[vital_cols] = tmp[vital_cols].interpolate(method='linear', limit_direction="both")
        out.append(tmp)
    return pd.concat(out, ignore_index=True)

# 2.其他化验指标（除了乳酸之外）：若入院 0–4h 基线窗口某列有数据 → 该列患者内前向填充；
# 剩余首尾空值 → 同患者该列均值兜底；
# lab_creatinine, lab_bilirubin_total, serum_co2 以48h为时间限制
lab_48h_limit = [c for c in ['lab_creatinine', 'lab_bilirubin_total', 'serum_co2'] if c in df.columns]
lab_general = [c for c in lab_cols if c not in lab_48h_limit]

def fill_lab(df_input):
    out = []
    for stay_id, patient in df_input.groupby("stay_id"):
        tmp = patient.copy()
        base_window = tmp[tmp["window_index"] == 0]
        has_baseline = base_window[lab_general].notna().any()  # 逐列布尔
        cols_with_base = has_baseline[has_baseline].index.tolist()
        if cols_with_base:
            tmp[cols_with_base] = tmp[cols_with_base].ffill()
        out.append(tmp)
    df_out = pd.concat(out, ignore_index=True)
    # 剩余首尾空值 → 同患者该列均值兜底
    df_out[lab_general] = df_out.groupby("stay_id")[lab_general].transform(lambda x: x.fillna(x.mean()))
    # 肌酐/胆红素/serum_co2：48h时限ffill，不做均值兜底（残留NaN保留）
    df_out = df_out.sort_values(["stay_id", "window_index"]).reset_index(drop=True)
    df_out[lab_48h_limit] = df_out.groupby("stay_id")[lab_48h_limit].ffill(limit=MAX_GAP_48H)
    return df_out

# 3.体重
def fill_weight(df_input):
    out = []
    for sid, subdf in df_input.groupby("stay_id"):
        valid_weight = subdf["weight_weight_kg"].dropna()
        if not valid_weight.empty:
            subdf["weight_weight_kg"] = valid_weight.iloc[0]
        out.append(subdf)
    df_out = pd.concat(out, ignore_index=True)
    df_out["age_bin"] = pd.cut(df_out["demo_anchor_age"], bins=[18, 40, 60, 80, 120])
    weight_group_median = df_out.dropna(subset=["weight_weight_kg"]).groupby(
        ["gender", "age_bin"])["weight_weight_kg"].median()

    def fill_by_group(row):
        if pd.notna(row["weight_weight_kg"]):
            return row["weight_weight_kg"]
        try:
            return weight_group_median.loc[row["gender"], row["age_bin"]]
        except KeyError:
            return row["weight_weight_kg"]

    df_out["weight_weight_kg"] = df_out.apply(fill_by_group, axis=1)
    return df_out.drop(columns="age_bin")

# 4.危重症评分：患者内ffill（48h时限）+ 同患者均值兜底
SCORE_COLS = [c for c in ["shock_index", "elixhauser", "gcs", "sirs",
                          "sofa_sofa2_total", "fio2", "pf_ratio"] if c in df.columns]

def fill_score(df_input):
    df_out = df_input.sort_values(["stay_id", "window_index"]).reset_index(drop=True)
    df_out[SCORE_COLS] = df_out.groupby("stay_id")[SCORE_COLS].ffill(limit=MAX_GAP_48H)
    df_out[SCORE_COLS] = df_out.groupby("stay_id")[SCORE_COLS].transform(lambda x: x.fillna(x.mean()))
    return df_out

# 5.尿量：24h block内已知总量平均分配到6个窗口（4h尿量 ≈ 24h尿量/6）；
#   block内全无数据的，同患者均值兜底
def fill_urine(df_input):
    def fill_block(g):
        g = g.sort_values("window_index").reset_index(drop=True)
        g["_24h_block"] = g["window_index"] // 6
        for block_id, block_df in g.groupby("_24h_block"):
            valid = block_df["urine_urine_output_4h_ml"].dropna()
            if not valid.empty:
                avg_4h = valid.sum() / 6
                mask = (g["_24h_block"] == block_id) & g["urine_urine_output_4h_ml"].isna()
                g.loc[mask, "urine_urine_output_4h_ml"] = avg_4h
        return g.drop(columns=["_24h_block"])

    df_out = df_input.groupby("stay_id", group_keys=False).apply(fill_block)
    df_out["urine_urine_output_4h_ml"] = df_out.groupby("stay_id")["urine_urine_output_4h_ml"].transform(
        lambda x: x.fillna(x.mean()))
    return df_out

# 6.机械通气：缺失填0
def fill_ventilation(df_input):
    df_input["mechanical_ventilation"] = df_input["mechanical_ventilation"].fillna(0)
    return df_input

# 7.乳酸：三种填补策略 + missingness indicator
def add_lactate_indicators(g):
    """缺失指示列：是否实测 + 距上次实测的小时数"""
    g = g.sort_values("window_index").reset_index(drop=True)
    g["ind_lab_lactate"] = (~g["lab_lactate"].isna()).astype(int)
    gap_list, last_valid_idx = [], None
    for idx, val in g["lab_lactate"].items():
        if not pd.isna(val):
            last_valid_idx = idx
            gap_list.append(0)
        else:
            gap_list.append(999 if last_valid_idx is None else (idx - last_valid_idx) * WINDOW_HOURS)
    g["gap_lab_lactate_hour"] = gap_list
    return g

def locf_fill_max_gap(g, max_windows):
    """前向LOCF：距上次实测超过 max_windows 个窗口则不填；起始缺失保留NaN"""
    res, last_measured, last_idx = [], np.nan, None
    for idx, val in g["lab_lactate"].items():
        if not pd.isna(val):
            last_measured, last_idx = val, idx
            res.append(val)
        else:
            if last_idx is None or (idx - last_idx) > max_windows:
                res.append(np.nan)
            else:
                res.append(last_measured)
    return res

def zhang_fill_series(g):
    """改进版Zhang风格：Day1(窗口0-5)缺失用首个实测值反向填充，之后标准LOCF；全轨迹无实测保留NaN"""
    first_valid_idx = g["lab_lactate"].first_valid_index()
    if first_valid_idx is None:
        return pd.Series(np.nan, index=g.index)
    first_val = g.loc[first_valid_idx, "lab_lactate"]
    filled = g["lab_lactate"].copy()
    day1_mask = g["window_index"] <= 5
    if first_valid_idx in g[day1_mask].index:
        loc_in_day1 = g[day1_mask].index.get_loc(first_valid_idx)
        day1_pre = g[day1_mask].index[:loc_in_day1]
        filled.loc[day1_pre] = filled.loc[day1_pre].fillna(first_val)
    else:
        filled.loc[day1_mask] = filled.loc[day1_mask].fillna(first_val)
    return filled.ffill()

def process_lactate_one_stay(g):
    g = add_lactate_indicators(g)
    # 策略一：24h LOCF
    g["lab_lactate_fill_24h"] = locf_fill_max_gap(g, MAX_GAP_24H)
    # 策略二：48h LOCF
    g["lab_lactate_fill_48h"] = locf_fill_max_gap(g, MAX_GAP_48H)
    # 策略三：改进版Zhang / revised
    g["lactate_revised"] = zhang_fill_series(g).values
    return g

def fill_lactate(df_input):
    return df_input.groupby("stay_id", group_keys=False).apply(process_lactate_one_stay)

## 统一处理数据集
def process_dataset(df_input):
    df_out = fill_vital(df_input)
    df_out = fill_lab(df_out)
    df_out = fill_weight(df_out)
    df_out = fill_score(df_out)
    df_out = fill_urine(df_out)
    df_out = fill_ventilation(df_out)
    df_out = fill_lactate(df_out)
    return df_out

df_1 = process_dataset(df_filtered.copy())           # main：保留低乳酸覆盖患者
df_2 = process_dataset(df_drop_lactate_low.copy())   # drop_lactate_low：剔除低乳酸覆盖患者

#### 缺失情况检查
for name, d in [("main", df_1), ("drop_lactate_low", df_2)]:
    print(f"\n=== {name} 乳酸三版缺失率 ===")
    for col in ["lab_lactate", "lab_lactate_fill_24h", "lab_lactate_fill_48h", "lactate_revised"]:
        n = d[col].isna().sum()
        print(f"{col}: 缺失{n} ({n / len(d) * 100:.2f}%)")

# 输出：每个文件只保留自己对应的乳酸列
LACTATE_VERSIONS = ["lab_lactate_fill_24h", "lab_lactate_fill_48h", "lactate_revised"]

def keep_only_lactate(df_input, keep_col):
    """只保留指定乳酸列；ind_lab_lactate/gap_lab_lactate_hour为共用辅助列，均保留"""
    drop = [c for c in LACTATE_VERSIONS if c != keep_col] + ["lab_lactate"]
    return df_input.drop(columns=drop)

outputs = {
    "main_45dim_24h.csv":                 keep_only_lactate(df_1, "lab_lactate_fill_24h"),
    "main_45dim_48h.csv":                 keep_only_lactate(df_1, "lab_lactate_fill_48h"),
    "main_45dim_revised.csv":             keep_only_lactate(df_1, "lactate_revised"),
    "drop_lactate_low_45dim_24h.csv":     keep_only_lactate(df_2, "lab_lactate_fill_24h"),
    "drop_lactate_low_45dim_48h.csv":     keep_only_lactate(df_2, "lab_lactate_fill_48h"),
    "drop_lactate_low_45dim_revised.csv": keep_only_lactate(df_2, "lactate_revised"),
}
for fname, d in outputs.items():
    d.to_csv(fname, index=False)
    print(f"已保存 {fname}: {d['stay_id'].nunique()} 患者, {len(d)} 窗口, {len(d.columns)} 列")
