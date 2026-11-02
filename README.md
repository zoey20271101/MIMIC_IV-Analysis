## Workflow

```mermaid
flowchart LR
    subgraph A[Data Extraction and Preprocessing]
        DB[(MIMIC-IV Database)] --> SCREEN[Sepsis cohort screening<br/>Age>18, ΔSOFA≥2, ICU first stay]
        SCREEN --> DIV[4h interval split + data cleaning & imputation]
        DIV --> DS[Extracted trajectory dataset]
    end

    subgraph B[MDP Construction: States / Actions / Rewards]
        ST[States<br/>Demographics, vital signs, labs, ventilation]
        ACT[Actions<br/>4 options: fluid / vasopressor / both / none]
        RWD[Rewards<br/>Lactate & SOFA change + 28-day mortality]
    end

    subgraph C[Offline RL Training: DDQN + CQL]
        SPLIT[Train/Val/Test split by subject_id]
        SPLIT --> NET[Q-network (128 x 128)]
        NET --> LOSS[Optimize total loss: L_total = L_TD + α*R_CQL]
    end

    subgraph D[Evaluation]
        BEST[Best trained model] --> REC[Recommended treatment actions]
        CLIN[Clinician actions]
        REC & CLIN --> MET[Metrics: Matching Rate, WIS]
    end

    A --> B
    B --> C
    C --> D

    classDef box fill:#f5f7fa,stroke:#446,stroke-width:1.5px
    class A,B,C,D box


---
```markdown
### Pipeline Overview
1. **Data Extraction and Preprocessing**: We extract sepsis trajectories from MIMIC-IV using SQL, apply inclusion/exclusion criteria, split records into 4-hour windows, perform cleaning and missing value imputation.
2. **MDP Construction**: Formulate sequential ICU treatment as an MDP. States include patient physiological features; actions are fluid/vasopressor decisions; reward is defined based on lactate, SOFA and 28-day mortality outcome.
3. **Offline RL Training**: Train Double DQN with CQL regularization on retrospective trajectories, split by patient ID to avoid data leakage.
4. **Evaluation**: Compare policy recommendations against clinician decisions using matching rate and weighted importance sampling (WIS).
