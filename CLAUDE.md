# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Julia-based pipeline for processing corporate bond market data from TRACE, FISD, and ICE sources. The pipeline transforms raw bond trading data into analysis-ready datasets with computed risk measures, returns, and factor signals.

**Key Data Sources:**
- **TRACE** (2002-2024): Primary intraday and daily trading data (from WRDS via SAS)
- **FISD** (Mergent): Bond characteristics, ratings, amounts outstanding (from WRDS via SAS)
- **WRDS**: Bond-equity links, Fama-French factors
- **Treasury/GSW**: Risk-free rates and yield curves (auto-downloaded from Fed)

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
julia --project=. scripts/main/create_datasets.jl       # 5-9 hours (complete pipeline)
```

**Error Checking Workflow** (after running main pipeline):
```bash
julia --project=. scripts/main/check_for_errors.jl      # 5-10 min
# Manual review of Excel files in data/error_checks/excel_YYYY_MM_DD/
# Add reviewed errors to data/error_checks/errors.xlsx (sheet: TRACE_error, cols: cusip, trade_date)
# Re-run check_for_errors.jl to check for additional errors (reviewed ones excluded)
```

**Optional utilities:**
```bash
python scripts/download_data/wrds_get_bond_rets.py     # Optional WRDS downloads
```

## Architecture

### Directory Structure

```
corp-bond-data/
├── config/                      # Configuration
│   └── update_config.jl        # Pipeline config (EDIT THIS for error checking)
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
├── scripts/                     # Pipeline scripts
│   ├── download_data/          # Data download scripts (RUN FIRST!)
│   │   ├── trace_filter.sas   # TRACE extraction (SAS Studio)
│   │   ├── get_fisd.sas       # FISD extraction (SAS Studio)
│   │   ├── stocks.sas         # Bond-equity links (SAS Studio)
│   │   └── wrds_get_bond_rets.py  # Optional WRDS downloads (Python)
│   └── main/                   # Main pipeline
│       ├── check_data_files.jl    # Verify data files
│       ├── create_datasets.jl     # Complete pipeline (5-9 hours)
│       ├── check_for_errors.jl    # Error detection workflow
│       └── utils_clean_data.jl    # Cleaning utilities
│
├── data/                       # Data directory
│   ├── wrds/                  # ALL WRDS data (TRACE, FISD, links, FF factors)
│   ├── data_to_share/         # PRIMARY OUTPUTS (end user datasets)
│   ├── output/                # Pipeline outputs (internal use)
│   ├── error_checks/          # Error checking files
│   │   ├── errors.xlsx        # Already-reviewed errors (sheet: TRACE_error)
│   │   └── excel_YYYY_MM_DD/  # Excel files for manual review
│   └── BondEqLink.csv         # Additional bond-equity links
│
├── tests/                      # Test files
│   ├── test_bonds_subset.jl   # Dataset validation tests
│   └── bonds_full_test.csv    # Reference dataset
│
├── .gitignore                  # Git ignore rules
├── Project.toml                # Julia dependencies
├── Manifest.toml               # Julia dependency versions
├── README.md                   # Project overview
└── CLAUDE.md                   # This file - developer guide
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

**Main Pipeline** (`scripts/main/create_datasets.jl`) - Complete end-to-end pipeline:

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
9. **Factor construction** → `factor_regressors.csv`, `bond_factors.csv`
10. **Value signals** → Add to bonds dataset
11. **Equity links** → Update PERMNO/PERMCO
12. **Final outputs** → `data/output/bonds_full.csv`, `data/output/firms_full.csv` (complete)
13. **Export subsets** → `data/data_to_share/bonds.csv`, `data/data_to_share/firms.csv` (PRIMARY OUTPUTS)

**Error Checking Workflow** (`scripts/main/check_for_errors.jl`) sequence:

1. **Run script** → `check_for_errors.jl` identifies extreme returns across entire dataset
2. **Exclude reviewed** → Automatically excludes returns already in `data/error_checks/errors.xlsx`
3. **Generate Excel files** → Creates detailed workbooks for manual review
4. **Manual review** → User reviews Excel files to classify errors vs. real market events
5. **Document errors** → Add reviewed (cusip, trade_date) pairs to `errors.xlsx` (sheet: TRACE_error)
6. **Re-run** → Re-run script to check for additional errors (reviewed ones excluded)

### Configuration System

**Main configuration file: `config/update_config.jl`**

This is the centralized configuration file for the entire pipeline.

**Used by:**
- `scripts/main/create_datasets.jl` (main pipeline)
- `scripts/main/check_for_errors.jl` (error checking)

**Key configuration parameters:**

**Processing parameters:**
- `N_WORKERS` - **Auto-detected:** Half of CPU cores + 1 (e.g., 16-core system → 9 workers)
  - You can override by setting manually in `update_config.jl`
  - Used for parallel bond valuation (most time-intensive step)

**Error checking parameters:**
- `UPDATE_DATE = "2025_11_11"` - Date identifier for Excel output directory
- `EXTREME_RETURN_THRESHOLD = 0.326` - Error detection threshold (±32.6%)
- `N_MONTHS_BACK = 4` - Months of data before extreme return to show in Excel
- `N_MONTHS_FORWARD = 2` - Months of data after extreme return to show in Excel

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
├── data_to_share/      # PRIMARY OUTPUTS (end user datasets)
│   ├── bonds.csv               # Bond-level dataset
│   └── firms.csv               # Firm-level dataset
│
├── output/             # Pipeline outputs (internal use)
│   ├── trace_daily.pq          # Main daily prices
│   ├── bonds_full.csv          # Complete bond-level dataset
│   ├── firms_full.csv          # Complete firm-level dataset
│   ├── illiq.csv               # Liquidity measures
│   ├── factor_regressors.csv   # Factor data
│   └── gsw.csv                 # GSW treasury curve (auto-downloaded)
│
└── error_checks/       # Error checking workflow
    ├── errors.xlsx             # Reviewed errors (sheet: TRACE_error)
    └── excel_YYYY_MM_DD/       # Excel files for manual review
```

## Important Technical Details

### Parallel Processing

Risk measure calculations use Julia's `Distributed` module:
```julia
using Distributed
addprocs(8, exeflags="--project")  # Add 8 workers
@everywhere using DataFramesMeta, RCall
@everywhere R"library(BondValuation)"
@everywhere include("../../src/main.jl")  # Load all modules

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
# STEP 2 in create_datasets.jl (after intraday load, before daily aggregation)
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
2. **Update config**: Edit `config/update_config.jl` for new paths/parameters
3. **Test incrementally**: Load modules in REPL and test functions
4. **Run full pipeline**: After testing, run `scripts/main/create_datasets.jl`

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
1. Add path constant in `config/update_config.jl`
2. Create loader function in `src/data_loader.jl`
3. Export from DataLoader module in `src/main.jl`

**Add new factor/signal:**
1. Implement in `src/factors.jl`
2. Export from Factors module
3. Integrate into `scripts/main/create_datasets.jl`

**Modify bond filtering:**
- Edit `Preprocess.filter_bonds!()` in `src/preprocessing.jl`
- Or add filters in specific pipeline stages

**Change parallel processing:**
- Modify `N_WORKERS` in `config/update_config.jl`
- Optimal: match number of physical CPU cores

**Update script organization:**
- Scripts are in `scripts/main/` and `scripts/download_data/`
- All `include()` paths use relative paths: `../../src/main.jl`, `utils_clean_data.jl`
- When moving scripts, update include paths accordingly

## Data Requirements

**Required files (from WRDS SAS Studio - RUN FIRST):**

Run SAS scripts in `scripts/download_data/` on WRDS SAS Studio, then place all output files in `data/wrds/`:
- `trace_prices.sas7bdat` (500MB-2GB) - TRACE intraday data
- `fisd_issue.sas7bdat` - FISD bond characteristics
- `fisd_ratings.sas7bdat` - FISD ratings
- `fisd_defaults.sas7bdat` - FISD defaults
- `fisd_amt_out.sas7bdat` - FISD amounts outstanding
- `fisd_amt_out_hist.sas7bdat` - FISD amounts historical
- `bondcrsp_link.sas7bdat` - Bond-equity links
- `stocks.csv` - Stock returns
- `ff_daily.csv` - Fama-French factors

**Required files (other sources):**
- `data/BondEqLink.csv` - Additional bond-equity mapping (provided separately)

**Auto-downloaded:**
- `data/output/gsw.csv` (Treasury curve parameters from Federal Reserve)

## Scripts Reference

### Main Pipeline (`scripts/main/`)

| Script | Purpose | Runtime | Key Outputs |
|--------|---------|---------|-------------|
| `check_data_files.jl` | Verify data, download GSW | 1 min | gsw.csv |
| `create_datasets.jl` | Complete pipeline (TRACE → factors → output) | 5-9 hrs | PRIMARY: data_to_share/bonds.csv, data_to_share/firms.csv; Also: data/output/* |
| `check_for_errors.jl` | Error detection across full dataset | 5-10 min | Excel files in error_checks/excel_YYYY_MM_DD/ |
| `utils_clean_data.jl` | Shared cleaning utilities | N/A | Used by other scripts |

**Configuration:** Edit `config/update_config.jl` to customize pipeline parameters.

**Error Checking Workflow:** Run `check_for_errors.jl` after `create_datasets.jl` → manually review Excel files → add reviewed errors to `data/error_checks/errors.xlsx` (sheet: TRACE_error) → re-run to check for additional errors.

### Data Download Scripts (`scripts/download_data/`)

**SAS scripts (run FIRST in WRDS SAS Studio):**
- `trace_filter.sas` - Extract TRACE intraday data
- `get_fisd.sas` - Extract FISD bond characteristics
- `stocks.sas` - Extract bond-equity linking tables

**Python script (optional):**
- `wrds_get_bond_rets.py` - Additional WRDS downloads

### Testing Scripts (`tests/`)

| Script | Purpose | Usage |
|--------|---------|-------|
| `test_bonds_subset.jl` | Test bonds_subset.csv against expected output | `julia --project=. tests/test_bonds_subset.jl` |

**Expected test file:** `tests/bonds_full_test.csv` - Reference dataset for validation

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

## Recent Changes (2025-11-19)

1. **Major cleanup** - Removed obsolete files and directories:
   - Deleted `docs/` directory (content moved to README.md and CLAUDE.md)
   - Deleted `scripts/archive/` (obsolete scripts)
   - Deleted empty data directories (`data/ice_new/`, `data/data_to_share/`, `data/output/update_2025_11_11/`)
   - All active functionality preserved in `scripts/main/` and `src/`

2. **Pipeline consolidation**:
   - `create_datasets.jl` now runs complete end-to-end pipeline (TRACE → factors → output)
   - Removed separate `create_factor_data.jl` script (functionality integrated)
   - Single script produces all outputs: `bonds_full.csv`, `firms.csv`, `bonds.csv`, `firms.csv`

3. **Error checking workflow simplified**:
   - `check_for_errors.jl` moved to `scripts/main/`
   - Error format: Excel sheet "TRACE_error" with columns `cusip`, `trade_date`
   - Any row in sheet is considered a reviewed error (no additional filtering)

4. **Project structure streamlined**:
   - Only 2 script directories: `scripts/main/` and `scripts/download_data/`
   - All utilities in `scripts/main/utils_clean_data.jl`
   - Configuration centralized in `config/update_config.jl`

5. **Documentation consolidated**:
   - README.md - Project overview and quick start
   - CLAUDE.md - Complete developer guide (this file)
   - All configuration and script documentation integrated into main docs
