# MIMIC_IV Analysis

```mermaid
flowchart TD
    A[MIMIC-IV BigQuery SQL] --> B[Cohort & feature extraction, export CSV]
    B --> C[preprocess.py<br>Clean, normalize, construct trajectory]
    C --> D[env.py<br>Build MDP: State / Action / Reward]
    D --> E[models.py<br>DDQN & CQL network]
    E --> F[train.py<br>Offline RL training]
    F --> G[results<br>Loss & reward curve, policy evaluation]
