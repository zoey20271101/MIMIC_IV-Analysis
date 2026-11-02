# MIMIC-IV Sepsis Offline RL Analysis
Offline reinforcement learning for sepsis ICU treatment decision analysis based on MIMIC-IV.

## Pipeline
1. Data extraction & preprocessing (SQL cohort, window splitting, missing imputation)
2. MDP setup: state, action, reward definition for sepsis treatment
3. Offline RL: Double DQN + CQL
4. Policy evaluation via WIS and clinician matching rate

> Note: This repo includes cohort extraction and preprocessing scripts only. RL training & evaluation code are withheld for manuscript preparation and MIMIC data compliance.

## Structure
- assets/: workflow figure
- code/: SQL and Python scripts for cohort and feature processing

Dataset: MIMIC-IV (PhysioNet, credential access required)
