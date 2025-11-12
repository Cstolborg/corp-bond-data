# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Julia-based pipeline for processing corporate bond market data from TRACE, FISD, and ICE sources. The pipeline transforms raw bond trading data into analysis-ready datasets with computed risk measures, returns, and factor signals.

**Key Data Sources:**
- **TRACE** (2002-2024): Primary intraday and daily trading data (from WRDS via SAS)
- **FISD** (Mergent): Bond characteristics, ratings, amounts outstanding (from WRDS via SAS)
- **WRDS**: Bond-equity links, Fama-French factors
- **Treasury/GSW**: Risk-free rates and yield curves (auto-downloaded from Fed)
- **ICE/Warga** (Optional): Additional/historical bond pricing

**Runtime:** Full pipeline takes 5-9 hours; bond yield calculations via R's BondValuation package are the main bottleneck (4-8 hours).

## Quick Reference

### Installation
```bash
# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Test R integration (required for bond valuation)
julia --project=. -e 'using RCall; R"library(BondValuation)"'
```

### Running Pipelines

**IMPORTANT:** Before any Julia scripts, run SAS scripts in `scripts/download_data/` on WRDS SAS Studio to extract TRACE and FISD data.

**Main Pipeline** (full historical data):
```bash
julia --project=. scripts/main/check_data_files.jl      # Verify data
julia --project=. scripts/main/create_datasets.jl       # 5-9 hours
julia --project=. scripts/main/create_factor_data.jl    # 30-60 min
```

**Update Pipeline** (incremental data):
```bash
# 1. Edit config/update_config.jl first (set UPDATE_DATE, TIMEPERIOD)
julia --project=. scripts/update/update_bond_data.jl    # 2-4 hours
julia --project=. scripts/update/check_for_errors.jl    # 5-10 min
# 2. Manual review of Excel files
julia --project=. scripts/update/merge_datasets.jl      # 5-10 min
julia --project=. scripts/main/create_factor_data.jl    # 30-60 min
```

**Other utilities:**
```bash
julia --project=. scripts/preprocessing/preprocess_new_ice.jl  # ICE data
julia --project=. scripts/export/data_to_share.jl              # Export datasets
python scripts/download_data/wrds_get_bond_rets.py             # WRDS downloads
```

## Architecture

### Directory Structure

```
corp-bond-data/
├── config/                      # Configuration
│   ├── data_paths.jl           # Main pipeline config
│   └── update_config.jl        # Update pipeline config (EDIT THIS for updates)
│
├── src/                         # Core modules
│   ├── main.jl                 # Module loader
│   ├── data_loader.jl          # TRACE/FISD/WRDS loading
│   ├── preprocessing.jl        # Bond valuation (R integration)
│   ├── compute_bond_returns.jl # Return calculations
│   ├── factors.jl              # Factor construction
│   ├── portfolios.jl           # Portfolio sorts
│   ├── utils.jl                # Utility functions
│   └── rating_conversions.jl   # Rating mappings
│
├── scripts/                     # Pipeline scripts (ORGANIZED)
│   ├── download_data/          # Data download scripts (RUN FIRST!)
│   │   ├── trace_filter.sas   # TRACE extraction (SAS Studio)
│   │   ├── get_fisd.sas       # FISD extraction (SAS Studio)
│   │   ├── stocks.sas         # Bond-equity links (SAS Studio)
│   │   └── wrds_get_bond_rets.py  # Optional WRDS downloads (Python)
│   ├── main/                   # Main pipeline
│   │   ├── check_data_files.jl
│   │   ├── create_datasets.jl
│   │   ├── create_factor_data.jl
│   │   └── create_characteristics.jl
│   ├── update/                 # Update pipeline
│   │   ├── update_bond_data.jl
│   │   ├── check_for_errors.jl
│   │   └── merge_datasets.jl
│   ├── preprocessing/          # Data preprocessing
│   │   └── preprocess_new_ice.jl
│   ├── export/                 # Data export
│   │   └── data_to_share.jl
│   ├── utils/                  # Shared utilities
│   │   └── utils_clean_data.jl  # Cleaning functions
│
├── data/                       # Data directory
│   ├── wrds/                  # ALL WRDS data (TRACE, FISD, links, FF factors)
│   ├── output/                # Pipeline outputs
│   │   └── update_YYYY_MM_DD/ # Update pipeline outputs
│   └── BondEqLink.csv         # Additional bond-equity links
│
└── docs/                       # Documentation
    ├── PIPELINE_WORKFLOW.md
    └── DATA_REQUIREMENTS.md
```

### Module System

The codebase uses a modular architecture defined in `src/main.jl`:

1. **DataLoader Module** (`src/data_loader.jl`)
   - Loads TRACE intraday/daily/monthly data
   - Loads FISD bond characteristics, ratings
   - Loads Fama-French factors, risk-free rates
   - Loads bond-equity links (CUSIP to PERMNO/GVKEY)

2. **Preprocess Module** (`src/preprocessing.jl`)
   - FISD bond characteristic processing via `Fisd()` struct
   - **Bond valuation via RCall** - calls R's BondValuation package
   - Core functions: `bond_values()`, `bond_dates()`
   - Treasury curve calculations
   - Monthly aggregation: `agg_daily_trace_to_month()`
   - ICE and Warga data processing

3. **Factors Module** (`src/factors.jl`)
   - Factor construction and portfolio sorts
   - Market factor computation
   - Rolling signals and characteristics

4. **Pfs (Portfolios) Module** (`src/portfolios.jl`)
   - Portfolio construction and analysis
   - Performance evaluation

**Key Utilities** (`src/utils.jl`, `scripts/utils/utils_clean_data.jl`, `src/rating_conversions.jl`):
- Date conversions, rating mappings
- Liquidity measures (Amihud illiquidity)
- Temporal feature functions
- Reversal flag computation
- Helper functions used across modules

### Pipeline Flow

**Main Pipeline** (`scripts/main/create_datasets.jl`) sequence:

1. **Load TRACE intraday** → Filter outlier prices via reversal flags
2. **Aggregate to daily** → `trace_daily.pq` (value-weighted)
3. **Aggregate to monthly** → `trace_monthly.csv` with returns
4. **Compute liquidity** → `illiq.csv` (Amihud measures)
5. **Bond risk measures** → `risk_measures_trace.csv` (PARALLEL via R BondValuation)
   - Uses `Distributed` module with multiple workers
   - Most time-intensive step (2-4 hours)
6. **Date/coupon vectors** → `date_vectors_trace.csv`, `dates_trace.csv`
7. **Bond returns** → `bonds.csv` (with temporal features, excess returns)
8. **Treasury risk** → `treasury_risk_measures_trace.csv` (PARALLEL, 2-4 hours)
9. **Save incomplete dataset** → `bonds_full.csv` (needs factors)

**Factor Pipeline** (`scripts/main/create_factor_data.jl`) sequence:

10. **Factor construction** → `factor_regressors.csv`, `bond_factors.csv`
11. **Value signals** → Add to bonds dataset
12. **Equity links** → Update PERMNO/PERMCO
13. **Final dataset** → `bonds_full.csv` (COMPLETE with all features)

**Update Pipeline** (`scripts/update/`) sequence:

1. **Configure** → Edit `config/update_config.jl` (UPDATE_DATE, TIMEPERIOD)
2. **Process new data** → `update_bond_data.jl` creates incremental dataset
3. **Error detection** → `check_for_errors.jl` creates Excel files for extreme returns
4. **Manual review** → User reviews Excel files
5. **Merge datasets** → `merge_datasets.jl` OVERWRITES main files in `data/output/`
6. **Regenerate factors** → `create_factor_data.jl` on updated dataset

### Configuration System

**Centralized config files in `config/`:**

1. **`config/data_paths.jl`** - Main pipeline configuration
   - Loaded automatically by `src/main.jl`
   - Contains:
     - Directory paths (TRACE_DIR, WRDS_DIR, OUTPUT_DIR)
     - Common file paths (BONDCRSP_LINK, FF_DAILY, GSW_FILE)
     - Pipeline parameters (MIN_PRICE_PAIRS, ROLLING_WINDOW_MONTHS, etc.)
   - Used by: Main pipeline scripts

2. **`config/update_config.jl`** - Update pipeline configuration
   - **USER MUST EDIT THIS FILE** before running update pipeline
   - Contains all constants for update scripts (UPDATE_DATE, TIMEPERIOD, N_WORKERS, etc.)
   - Used by: `update_bond_data.jl`, `check_for_errors.jl`, `merge_datasets.jl`
   - Auto-generates: PATH, EXCEL_PATH, OUTPUT_SUFFIX
   - Benefits: Single source of truth - change config in ONE place, all three scripts use it

**Key configuration parameters:**

From `config/data_paths.jl`:
- `MIN_PRICE_PAIRS = 5` - Minimum price pairs for illiquidity calculation
- `MAX_DAYS_BETWEEN_PRICES = 7` - Max days between price observations
- `ROLLING_WINDOW_MONTHS = 36` - Rolling window for signal computation (3 years)
- `N_PORTFOLIOS = 5` - Number of portfolios for characteristic sorts
- `VAR_QUANTILE = 0.05` - VaR quantile level

From `config/update_config.jl` (user must edit):
- `UPDATE_DATE = "2025_11_11"` - Date identifier for update directory
- `TIMEPERIOD = "_2024_2025"` - Suffix for TRACE file
- `N_WORKERS = 8` - Number of parallel workers
- `EXTREME_RETURN_THRESHOLD = 0.326` - Error detection threshold (±32.6%)
- `START_YEAR = 2002` - First year of historical data
- `END_YEAR = 2024` - Last year after merge

### Data Directory Structure

```
data/
├── wrds/               # ALL WRDS data files (from SAS Studio)
│   ├── trace_prices.sas7bdat              # TRACE intraday (main)
│   ├── trace_prices_2024_2025.sas7bdat   # TRACE incremental
│   ├── fisd_issue.sas7bdat                # FISD bond issues
│   ├── fisd_ratings.sas7bdat              # FISD ratings
│   ├── fisd_defaults.sas7bdat             # FISD defaults
│   ├── fisd_amt_out.sas7bdat              # FISD amounts outstanding
│   ├── fisd_amt_out_hist.sas7bdat         # FISD amounts historical
│   ├── bondcrsp_link.sas7bdat             # Bond-equity links
│   └── ff_daily.csv                       # Fama-French factors
│
├── BondEqLink.csv      # Additional CUSIP-PERMNO mapping
│
└── output/             # All pipeline outputs
    ├── trace_daily.pq          # Main daily prices
    ├── bonds_full.csv          # Main analysis dataset
    ├── illiq.csv               # Liquidity measures
    ├── factor_regressors.csv   # Factor data
    ├── gsw.csv                 # GSW treasury curve (auto-downloaded)
    │
    └── update_2025_11_11/      # Update pipeline outputs
        ├── trace_daily_2024_2025.pq
        ├── bonds_full.csv
        ├── illiq_2024_2025.csv
        └── excel_files/        # Error review Excel files
```

## Important Technical Details

### Parallel Processing

Risk measure calculations use Julia's `Distributed` module:
```julia
using Distributed
addprocs(8, exeflags="--project")  # Add 8 workers
@everywhere using DataFramesMeta, RCall
@everywhere R"library(BondValuation)"
@everywhere include("../../src/main.jl")  # Note: paths updated for new structure

# Split data and parallel map
partitions = [...split grouped data...]
res = pmap(x->Preprocess.bond_values(x, treasury=false), partitions)
```

### R Integration via RCall

Bond yield and duration calculations require R:
```julia
using RCall
R"""
library(BondValuation)
# Calculations happen in R, results returned to Julia
"""
```

**Common issue:** If RCall can't find R, set `ENV["R_HOME"]` and rebuild:
```julia
ENV["R_HOME"] = "C:/Program Files/R/R-4.4.3"  # Windows
using Pkg; Pkg.build("RCall")
```

### Data Filtering

Standard bond filters (in `Preprocess.filter_bonds!()`):
- Coupon types: "F" (Fixed), "Z" (Zero) only
- Non-convertible bonds
- Valid maturity dates (must be >= 1 year)
- Valid ratings (1-22 scale)
- Remove defaulted bonds
- Remove bonds with price anomalies

### Reversal Flags (Outlier Detection)

**CRITICAL:** Must be computed BEFORE daily aggregation, not after.

From `scripts/utils/utils_clean_data.jl`:
```julia
function compute_reversal_flags!(df; price_col::Symbol=:price)
    # Flags prices that are 2x neighbors or 0.5x neighbors
    # Applied at intraday level before aggregation to daily
end
```

Usage in pipeline:
```julia
# STEP 2 in update_bond_data.jl (after intraday load, before daily aggregation)
trace_intraday.keep .= true
transform!(groupby(trace_intraday, :cusip), compute_reversal_flags!)
@subset!(trace_intraday, :keep .== true)  # Remove flagged outliers
```

### Rating System

Ratings converted to 1-22 numeric scale via `src/rating_conversions.jl`:
- 1 = AAA (highest)
- 22 = D (default)
- Functions: `letter_rating_to_numeric()`, `numeric_rating_to_letter()`

### Liquidity Measures

Amihud illiquidity computed in `scripts/utils/utils_clean_data.jl`:
- Function: `compute_illiq(trace_daily)`
- Requires minimum price pairs (default: 5)
- Maximum days between prices (default: 7)

### Temporal Features

From `scripts/utils/utils_clean_data.jl`:
- `get_dates()` - Load coupon date vectors (supports custom file paths for update pipeline)
- `get_temporal_features()` - Calculate time to next coupon
- `add_temporal_features()` - Add features to bond dataset (supports custom file paths)

**Important:** These functions now accept optional `file` parameter for update pipeline:
```julia
# Main pipeline (uses default paths)
add_temporal_features(bonds; trace=true)

# Update pipeline (uses custom path)
add_temporal_features(bonds; trace=true, file=PATH*"date_vectors_trace.csv")
```

## Development Workflow

### Adding New Features

1. **Modify modules in `src/`**: Changes automatically picked up via `include()`
2. **Update config**: Edit `config/data_paths.jl` or `config/update_config.jl` for new paths/parameters
3. **Test incrementally**: Load modules in REPL and test functions
4. **Run full pipeline**: After testing, run relevant script in `scripts/main/` or `scripts/update/`

### Testing Changes

```julia
# Start Julia REPL
julia --project=.

# Load pipeline
include("src/main.jl")

# Test specific module function
df = DataLoader.load_trace_intraday()
# ... test transformations ...

# Test with small subset to avoid long runtime
@subset!(df, :date .< Date(2024, 1, 31))  # Jan 2024 only
```

### Common Development Tasks

**Add new data source:**
1. Add path constant in `config/data_paths.jl`
2. Create loader function in `src/data_loader.jl`
3. Export from DataLoader module in `src/main.jl`

**Add new factor/signal:**
1. Implement in `src/factors.jl`
2. Export from Factors module
3. Integrate into `scripts/main/create_factor_data.jl`

**Modify bond filtering:**
- Edit `Preprocess.filter_bonds!()` in `src/preprocessing.jl`
- Or add filters in specific pipeline stages

**Change parallel processing:**
- Modify `N_WORKERS` in `config/update_config.jl`
- Optimal: match number of physical CPU cores

**Update script organization:**
- Scripts are now organized in subdirectories (`main/`, `update/`, etc.)
- All `include()` paths use relative paths: `../../src/main.jl`, `../utils/utils_clean_data.jl`
- When moving scripts, update include paths accordingly

## Data Requirements

**See `docs/DATA_REQUIREMENTS.md` for detailed data download instructions.**

**Required files (from WRDS SAS Studio - RUN FIRST):**

All files go in `data/wrds/`:
- `trace_prices.sas7bdat` (500MB-2GB) - TRACE intraday data
- `fisd_issue.sas7bdat` - FISD bond characteristics
- `fisd_ratings.sas7bdat` - FISD ratings
- `fisd_defaults.sas7bdat` - FISD defaults
- `fisd_amt_out.sas7bdat` - FISD amounts outstanding
- `fisd_amt_out_hist.sas7bdat` - FISD amounts historical
- `bondcrsp_link.sas7bdat` - Bond-equity links
- `ff_daily.csv` - Fama-French factors

**Required files (other sources):**
- `data/BondEqLink.csv` - Additional bond-equity mapping

**Auto-downloaded:**
- `data/output/gsw.csv` (Treasury curve parameters from Federal Reserve)

**Optional:**
- `data/ice_new/ICE_GI00.csv` (for ICE pipeline)
- Warga data (for historical/OOS analysis)

## Scripts Reference

### Main Pipeline (`scripts/main/`)

| Script | Purpose | Runtime | Key Outputs |
|--------|---------|---------|-------------|
| `check_data_files.jl` | Verify data, download GSW | 1 min | gsw.csv |
| `create_datasets.jl` | Main TRACE pipeline | 5-9 hrs | trace_daily.pq, bonds_full.csv (incomplete) |
| `create_factor_data.jl` | Factor construction | 30-60 min | factor_regressors.csv, bonds_full.csv (complete) |
| `create_characteristics.jl` | Bond characteristics | Variable | Characteristic portfolios |

### Update Pipeline (`scripts/update/`)

| Script | Purpose | Runtime | Key Outputs |
|--------|---------|---------|-------------|
| `update_bond_data.jl` | Process incremental data | 2-4 hrs | All files in update_YYYY_MM_DD/ |
| `check_for_errors.jl` | Error detection | 5-10 min | Excel files for review |
| `merge_datasets.jl` | Merge old + new | 5-10 min | Overwrites main files in data/output/ |

**Configuration:** Edit `config/update_config.jl` before running update pipeline.

### Data Download Scripts (`scripts/download_data/`)

**SAS scripts (run FIRST in WRDS SAS Studio):**
- `trace_filter.sas` - Extract TRACE intraday data
- `get_fisd.sas` - Extract FISD bond characteristics
- `stocks.sas` - Extract bond-equity linking tables

**Python script (optional):**
- `wrds_get_bond_rets.py` - Additional WRDS downloads

### Other Scripts

- `scripts/preprocessing/preprocess_new_ice.jl` - ICE data preprocessing
- `scripts/export/data_to_share.jl` - Create shareable datasets

## Performance Notes

- **Full pipeline runtime:** 5-9 hours
  - Intraday load: 5-10 min
  - Daily aggregation: 5 min
  - Bond risk measures: 2-4 hours (bottleneck)
  - Treasury risk measures: 2-4 hours (bottleneck)
  - Factor construction: 20-30 min
- **Memory:** 4-8GB RAM required
- **Optimization:** Use SSD for data storage, adjust worker count to CPU cores

## Key Dependencies

- **Julia 1.10+**
- **R 4.0+** with packages: BondValuation, R.utils
- **Python 3.8+** (optional, for WRDS downloads): pandas, numpy, wrds
- **SAS Studio** (WRDS): For initial data extraction

Julia packages (from Project.toml):
- DataFrames, DataFramesMeta, CSV, Parquet
- RCall (R integration)
- SASLib (read WRDS .sas7bdat files)
- Distributed (parallel processing)
- GLM, StatsBase, Statistics
- ShiftedArrays, Roots, Dates, XLSX

## Recent Changes (2025-11-11/12)

1. **Scripts reorganized** into subdirectories:
   - `scripts/download_data/` - Data download scripts (SAS + Python) - RUN FIRST
   - `scripts/main/` - Main pipeline
   - `scripts/update/` - Update pipeline
   - `scripts/preprocessing/` - Data preprocessing (ICE)
   - `scripts/export/` - Data export
   - `scripts/utils/` - Shared utilities

2. **Configuration centralized** in `config/`:
   - `config/data_paths.jl` - Main pipeline
   - `config/update_config.jl` - Update pipeline (single source of truth)

3. **Update pipeline refactored**:
   - `merge_datasets.jl` now OVERWRITES main files in `data/output/`
   - No manual file copying needed
   - Error detection via Excel file export

4. **Utility functions enhanced**:
   - `add_temporal_features()` now accepts custom file paths
   - `get_dates()` now accepts custom file paths
   - Reversal flags correctly placed before daily aggregation

5. **Documentation improved**:
   - README.md - Complete installation and execution order
   - scripts/README.md - Scripts reference
   - config/README.md - Configuration guide
   - Emphasizes SAS Studio prerequisite
