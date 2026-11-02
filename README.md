## Workflow
```mermaid
flowchart LR
    %% 第一块：数据提取与预处理
    subgraph A[Data Extraction and Preprocessing]
        DB[(MIMIC-IV Database)] --> SCREEN[Sepsis cohort screening<br/>Age>18, ΔSOFA≥2, ICU first stay]
        SCREEN --> DIV[4h interval split + data cleaning & imputation]
        DIV --> DS[Extracted trajectory dataset]
    end

    %% 第二块：MDP 状态、动作、奖励定义
    subgraph B[MDP Construction: States / Actions / Rewards]
        ST[States<br/>Demographics, vital signs, labs, ventilation]
        ACT[Actions<br/>4 options: fluid / vasopressor / both / none]
        RWD[Rewards<br/>Lactate & SOFA change + 28-day mortality]
    end

    %% 第三块：离线RL训练 DDQN + CQL
    subgraph C[Offline RL Training: DDQN + CQL]
        SPLIT[Train/Val/Test split by subject_id]
        SPLIT --> NET[Q-network (128×128)]
        NET --> LOSS[Optimize total loss: $\mathcal{L}_{total}=\mathcal{L}_{TD}+\alpha\mathcal{R}_{CQL}$]
    end

    %% 第四块：模型评估
    subgraph D[Evaluation]
        BEST[Best trained model] --> REC[Recommended treatment actions]
        CLIN[Clinician actions]
        REC & CLIN --> MET[Metrics: Matching Rate, WIS]
    end

    %% 箭头串联流程
    A --> B
    B --> C
    C --> D

    %% 样式美化（学术低调）
    classDef box fill:#f5f7fa,stroke:#446,stroke-width:1.5px
    class A,B,C,D box


---
```markdown
### Pipeline Overview
1. **Data Extraction and Preprocessing**: We extract sepsis trajectories from MIMIC-IV using SQL, apply inclusion/exclusion criteria, split records into 4-hour windows, perform cleaning and missing value imputation.
2. **MDP Construction**: Formulate sequential ICU treatment as an MDP. States include patient physiological features; actions are fluid/vasopressor decisions; reward is defined based on lactate, SOFA and 28-day mortality outcome.
3. **Offline RL Training**: Train Double DQN with CQL regularization on retrospective trajectories, split by patient ID to avoid data leakage.
4. **Evaluation**: Compare policy recommendations against clinician decisions using matching rate and weighted importance sampling (WIS).
