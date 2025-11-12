# Scripts Directory

This directory contains all pipeline scripts, organized by function.

## Directory Structure

```
scripts/
├── download_data/          # Data download scripts (RUN FIRST!)
├── main/                   # Main pipeline (full dataset creation)
├── update/                 # Update pipeline (incremental updates)
├── preprocessing/          # Data preprocessing utilities
├── export/                 # Data export scripts
└── utils/                  # Shared utility functions
```

## Data Download (`download_data/`)

**MUST BE RUN FIRST** before any Julia pipeline scripts.

Scripts for downloading raw data from WRDS.

### SAS Scripts (run in WRDS SAS Studio)

Upload and run these files in WRDS SAS Studio (wrds-www.wharton.upenn.edu):

**`trace_filter.sas`**
- Extracts TRACE intraday trading data
- Output: `trace_prices.sas7bdat` (~500MB-2GB)
- Place in: `data/wrds/`

**`get_fisd.sas`**
- Extracts FISD bond characteristics, ratings, amounts outstanding
- Outputs:
  - `fisd_issue.sas7bdat` - Bond issues
  - `fisd_ratings.sas7bdat` - Ratings
  - `fisd_defaults.sas7bdat` - Defaults
  - `fisd_amt_out.sas7bdat` - Amounts outstanding
  - `fisd_amt_out_hist.sas7bdat` - Amounts historical
- Place in: `data/wrds/`

**`stocks.sas`**
- Extracts bond-equity linking tables
- Output: `bondcrsp_link.sas7bdat`
- Place in: `data/wrds/`

### Python Script (optional)

**`wrds_get_bond_rets.py`**
- Downloads additional WRDS data (Fama-French factors, etc.)
- Requires WRDS Python package: `pip install wrds`
- Usage: `python scripts/download_data/wrds_get_bond_rets.py`

## Main Pipeline (`main/`)

Scripts for creating the complete bond dataset from scratch.

### `create_datasets.jl`
**Purpose:** Process full TRACE data (2002-2024) into analysis-ready bond dataset
**Runtime:** 5-9 hours
**Usage:**
```bash
julia --project=. scripts/main/create_datasets.jl
```
**Outputs:**
- `data/output/trace_daily.pq` - Daily bond prices
- `data/output/bonds_full.csv` - Main bond dataset (incomplete, needs factors)
- `data/output/illiq.csv` - Liquidity measures
- Risk measures, coupon schedules, date vectors

### `create_factor_data.jl`
**Purpose:** Generate factor returns and value signals
**Runtime:** 20-30 minutes
**Usage:**
```bash
julia --project=. scripts/main/create_factor_data.jl
```
**Outputs:**
- `data/output/factor_regressors.csv` - Factor data for regressions
- `data/output/factor_regressors_bbw.csv` - BBW-style factors
- `data/output/bonds_full.csv` - Updated with value signals and equity links

### `create_characteristics.jl`
**Purpose:** Create bond characteristic portfolios
**Usage:**
```bash
julia --project=. scripts/main/create_characteristics.jl
```

### `check_data_files.jl`
**Purpose:** Validate required data files and download missing data (GSW)
**Usage:**
```bash
julia --project=. scripts/main/check_data_files.jl
```

## Update Pipeline (`update/`)

Scripts for incrementally updating the bond dataset with new data.

### Workflow

1. **Configure:** Edit `config/update_config.jl` to set UPDATE_DATE and TIMEPERIOD
2. **Process:** Run `update_bond_data.jl` to process new TRACE data
3. **Check:** Run `check_for_errors.jl` to identify extreme returns
4. **Review:** Manually review Excel files in `data/output/update_YYYY_MM_DD/excel_files/`
5. **Merge:** Run `merge_datasets.jl` to merge with historical data

### `update_bond_data.jl`
**Purpose:** Process incremental TRACE data through full pipeline
**Runtime:** 2-4 hours (depends on data size)
**Usage:**
```bash
# 1. Edit config/update_config.jl first
# 2. Run:
julia --project=. scripts/update/update_bond_data.jl
```
**Outputs:** All files in `data/output/update_YYYY_MM_DD/`

### `check_for_errors.jl`
**Purpose:** Detect extreme bond returns and create Excel files for manual review
**Runtime:** 5-10 minutes
**Usage:**
```bash
julia --project=. scripts/update/check_for_errors.jl
```
**Outputs:** Excel files in `data/output/update_YYYY_MM_DD/excel_files/`

### `merge_datasets.jl`
**Purpose:** Merge cleaned incremental data with historical dataset
**Runtime:** 5-10 minutes
**Usage:**
```bash
julia --project=. scripts/update/merge_datasets.jl
```
**Outputs:** Overwrites main files in `data/output/`:
- `trace_daily.pq`
- `bonds_full.csv`
- `illiq.csv`

## Preprocessing (`preprocessing/`)

Data preprocessing utilities.

### `preprocess_new_ice.jl`
**Purpose:** Preprocess ICE bond data (optional)
**Usage:**
```bash
julia --project=. scripts/preprocessing/preprocess_new_ice.jl
```

## Export (`export/`)

Scripts for creating shareable datasets.

### `data_to_share.jl`
**Purpose:** Create clean, shareable bond and firm return datasets
**Usage:**
```bash
julia --project=. scripts/export/data_to_share.jl
```

## Utilities (`utils/`)

Shared utility functions used across multiple scripts.

### `utils_clean_data.jl`
**Purpose:** Common data cleaning functions
**Functions:**
- `compute_illiq()` - Amihud illiquidity calculation
- `get_dates()` - Load coupon date vectors
- `add_temporal_features()` - Add time-to-coupon features
- `compute_reversal_flags!()` - Flag price outliers

**Usage:** Included automatically by other scripts

## Quick Reference

### Complete Pipeline (from scratch)

**STEP 0: Download data from WRDS (MUST DO FIRST)**
```bash
# Upload and run SAS files in WRDS SAS Studio:
# - scripts/download_data/trace_filter.sas
# - scripts/download_data/get_fisd.sas
# - scripts/download_data/stocks.sas
# Download ALL .sas7bdat files and place in data/wrds/
```

**STEP 1-3: Run Julia pipeline**
```bash
# 1. Check/download data
julia --project=. scripts/main/check_data_files.jl

# 2. Create main dataset (5-9 hours)
julia --project=. scripts/main/create_datasets.jl

# 3. Create factors (20-30 min)
julia --project=. scripts/main/create_factor_data.jl
```

### Update Pipeline (incremental)
```bash
# 1. Configure (edit config/update_config.jl)

# 2. Process new data (2-4 hours)
julia --project=. scripts/update/update_bond_data.jl

# 3. Check for errors (5-10 min)
julia --project=. scripts/update/check_for_errors.jl

# 4. Manual review of Excel files

# 5. Merge datasets (5-10 min)
julia --project=. scripts/update/merge_datasets.jl

# 6. Regenerate factors (20-30 min)
julia --project=. scripts/main/create_factor_data.jl
```

## Configuration

All pipeline parameters are centralized in:
- `config/data_paths.jl` - Paths and pipeline parameters (used by main pipeline)
- `config/update_config.jl` - Update pipeline configuration

See [config/README.md](../config/README.md) for details.

## See Also

- [Main README](../README.md) - Project overview
- [Pipeline Workflow](../docs/PIPELINE_WORKFLOW.md) - Detailed workflow documentation
- [CLAUDE.md](../CLAUDE.md) - Developer guide for Claude Code
