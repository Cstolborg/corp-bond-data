# Corporate Bond Data Pipeline

A Julia-based pipeline for processing corporate bond market data from TRACE, FISD, and ICE sources, transforming raw trading data into analysis-ready datasets with computed risk measures, returns, and factor signals.

## Table of Contents

- [Quick Start](#quick-start)
- [Installation](#installation)
- [Data Download](#data-download)
- [Pipeline Execution Order](#pipeline-execution-order)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Documentation](#documentation)

## Quick Start

**Prerequisites:** Julia 1.10+, R 4.0+ with BondValuation, WRDS account

```bash
# 1. Install dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# 2. Download data via SAS (see Data Download section)

# 3. Run main pipeline
julia --project=. scripts/main/check_data_files.jl
julia --project=. scripts/main/create_datasets.jl       # 5-9 hours
julia --project=. scripts/main/create_factor_data.jl    # 30-60 min
```

**For incremental updates**, see [Update Pipeline](#update-pipeline-incremental-data).

## Installation

### 1. Prerequisites

| Software | Version | Purpose |
|----------|---------|---------|
| **Julia** | 1.10+ | Main pipeline language |
| **R** | 4.0+ | Bond valuation (BondValuation package) |
| **Python** | 3.8+ (optional) | WRDS data downloads |
| **WRDS Account** | - | Required for TRACE/FISD downloads |
| **SAS Studio** | - | Initial data extraction from WRDS |

### 2. Julia Setup

```bash
# Clone repository
git clone <your-repo-url>
cd corp-bond-data

# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Verify R integration
julia --project=. -e 'using RCall; R"library(BondValuation)"'
```

**If RCall cannot find R:**
```julia
# Set R_HOME and rebuild RCall
julia --project=. -e 'ENV["R_HOME"] = "C:/Program Files/R/R-4.4.3"; using Pkg; Pkg.build("RCall")'
```

### 3. R Setup

Install required R packages:
```r
install.packages("BondValuation")
install.packages("R.utils")
```

### 4. Python Setup (Optional)

For WRDS downloads using Python:
```bash
pip install pandas numpy wrds
```

## Data Download

### Step 1: Download Data from WRDS

**IMPORTANT:** This must be done FIRST before running any Julia scripts.

The `scripts/download_data/` directory contains programs to download raw data from WRDS:

**SAS scripts (run in WRDS SAS Studio):**
1. Navigate to WRDS SAS Studio (wrds-www.wharton.upenn.edu)
2. Upload and run the SAS files from `scripts/download_data/`:
   - `trace_filter.sas` - Extract TRACE intraday data → `trace_prices.sas7bdat` (500MB-2GB)
   - `get_fisd.sas` - Extract FISD bond characteristics, ratings, amounts outstanding
   - `stocks.sas` - Extract bond-equity linking tables
3. Download the `.sas7bdat` output files to your local machine

**Python script (optional, for additional WRDS data):**
```bash
python scripts/download_data/wrds_get_bond_rets.py
```

### Step 2: Organize Downloaded Data

Place ALL downloaded files in `data/wrds/`:

```
data/
├── wrds/                            # ALL WRDS data files go here
│   ├── trace_prices.sas7bdat       # TRACE intraday (from SAS Studio)
│   ├── fisd_issue.sas7bdat         # FISD bond issues (from SAS Studio)
│   ├── fisd_ratings.sas7bdat       # FISD ratings (from SAS Studio)
│   ├── fisd_defaults.sas7bdat      # FISD defaults (from SAS Studio)
│   ├── fisd_amt_out.sas7bdat       # FISD amounts outstanding (from SAS Studio)
│   ├── fisd_amt_out_hist.sas7bdat  # FISD amounts historical (from SAS Studio)
│   ├── bondcrsp_link.sas7bdat      # Bond-equity links (from SAS Studio)
│   └── ff_daily.csv                # Fama-French factors (WRDS web download)
│
└── BondEqLink.csv                   # Additional bond-equity link (provided separately)
```

### Step 3: Verify Data Files

```bash
julia --project=. scripts/main/check_data_files.jl
```

This script will:
- ✅ Verify all required files are present
- ✅ Auto-download GSW treasury curve from Federal Reserve
- ❌ Report any missing files

**Auto-downloaded files:**
- `data/output/gsw.csv` - GSW treasury yield curve parameters (Federal Reserve)

### Required vs Optional Files

**Required (must have):**
- `data/wrds/trace_prices.sas7bdat` - TRACE intraday data
- `data/wrds/fisd_issue.sas7bdat` - FISD bond characteristics
- `data/wrds/fisd_ratings.sas7bdat` - FISD ratings
- `data/wrds/fisd_defaults.sas7bdat` - FISD defaults
- `data/wrds/fisd_amt_out.sas7bdat` - FISD amounts outstanding
- `data/wrds/fisd_amt_out_hist.sas7bdat` - FISD amounts historical
- `data/wrds/bondcrsp_link.sas7bdat` - Bond-equity links
- `data/wrds/ff_daily.csv` - Fama-French factors
- `data/BondEqLink.csv` - Additional bond-equity mapping

**Optional:**
- `data/ice_new/ICE_GI00.csv` - ICE bond data (for ICE pipeline)
- Warga data - Historical/out-of-sample analysis

**See [docs/DATA_REQUIREMENTS.md](docs/DATA_REQUIREMENTS.md) for detailed download instructions.**

## Pipeline Execution Order

### Main Pipeline (Historical Data - First Time Setup)

Run these scripts **in order** after downloading data:

```bash
# STEP 0: Verify data files exist and download GSW
julia --project=. scripts/main/check_data_files.jl
# ⏱️ Runtime: 1 minute
# ✅ Outputs: data/output/gsw.csv

# STEP 1: Process historical TRACE data
julia --project=. scripts/main/create_datasets.jl
# ⏱️ Runtime: 5-9 hours (bond valuation is slow)
# ✅ Outputs:
#    - data/output/trace_daily.pq (daily prices)
#    - data/output/bonds_full.csv (main dataset, incomplete)
#    - data/output/illiq.csv (liquidity measures)
#    - data/output/risk_measures_trace.csv
#    - data/output/date_vectors_trace.csv

# STEP 2: Create factor returns and finalize dataset
julia --project=. scripts/main/create_factor_data.jl
# ⏱️ Runtime: 30-60 minutes
# ✅ Outputs:
#    - data/output/factor_regressors.csv (factor data)
#    - data/output/factor_regressors_bbw.csv (BBW factors)
#    - data/output/bonds_full.csv (UPDATED with signals & equity links)
```

**Total runtime:** ~6-10 hours (mostly bond valuation)

### Update Pipeline (Incremental Data)

When you have new TRACE data (e.g., 2024-2025) to add to your existing dataset:

```bash
# STEP 0: Configure the update
# Edit config/update_config.jl:
#   UPDATE_DATE = "2025_11_11"       # Today's date
#   TIMEPERIOD = "_2024_2025"        # Suffix of your new TRACE file

# STEP 1: Process new incremental data
julia --project=. scripts/update/update_bond_data.jl
# ⏱️ Runtime: 2-4 hours
# ✅ Outputs: All files in data/output/update_2025_11_11/

# STEP 2: Check for extreme returns (data quality)
julia --project=. scripts/update/check_for_errors.jl
# ⏱️ Runtime: 5-10 minutes
# ✅ Outputs: Excel files in data/output/update_2025_11_11/excel_files/
#            (one Excel file per bond with extreme returns)

# STEP 3: MANUAL REVIEW (your task)
# Open Excel files and review extreme bond returns
# Mark any confirmed data errors in spreadsheet
# Optional: Create error exclusion file

# STEP 4: Merge new data with historical dataset
julia --project=. scripts/update/merge_datasets.jl
# ⏱️ Runtime: 5-10 minutes
# ✅ Outputs: OVERWRITES main files in data/output/
#    - data/output/trace_daily.pq
#    - data/output/bonds_full.csv
#    - data/output/illiq.csv

# STEP 5: Regenerate factors on updated dataset
julia --project=. scripts/main/create_factor_data.jl
# ⏱️ Runtime: 30-60 minutes
# ✅ Outputs: Updated factor files
```

**Total runtime:** ~3-5 hours + manual review time

## Project Structure

### Directory Organization

```
corp-bond-data/
├── config/                      # Configuration files
│   ├── data_paths.jl           # Main pipeline paths & parameters
│   ├── update_config.jl        # Update pipeline configuration
│   └── README.md               # Config documentation
│
├── src/                         # Core Julia modules
│   ├── main.jl                 # Module loader
│   ├── data_loader.jl          # TRACE/FISD/WRDS loading
│   ├── preprocessing.jl        # Bond valuation (R integration)
│   ├── compute_bond_returns.jl # Return calculations
│   ├── factors.jl              # Factor construction
│   ├── portfolios.jl           # Portfolio sorts
│   ├── utils.jl                # Utility functions
│   └── rating_conversions.jl   # Rating mappings (AAA=1, D=22)
│
├── scripts/                     # Pipeline scripts (organized by function)
│   ├── download_data/          # Data download scripts (run FIRST)
│   │   ├── trace_filter.sas   # TRACE data extraction (SAS Studio)
│   │   ├── get_fisd.sas       # FISD data extraction (SAS Studio)
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
│   │   └── utils_clean_data.jl
│   └── README.md              # Scripts documentation
│
├── data/                       # Data directory (user-created)
│   ├── wrds/                  # ALL WRDS data files (TRACE, FISD, links, FF factors)
│   ├── output/                # Pipeline outputs
│   │   └── update_YYYY_MM_DD/ # Update pipeline outputs
│   └── BondEqLink.csv         # Additional bond-equity links
│
├── docs/
│   ├── PIPELINE_WORKFLOW.md   # Detailed workflow guide
│   └── DATA_REQUIREMENTS.md   # Data download instructions
│
├── tests/
│   └── compare_outputs.jl     # Output validation
│
├── CLAUDE.md                   # Developer guide for Claude Code
├── README.md                   # This file
└── Project.toml               # Julia dependencies
```

### Key Output Files

**Main dataset:** `data/output/bonds_full.csv`
- One row per bond-month observation
- ~2M+ observations (2002-2024)
- Key columns:
  - `cusip` - Bond identifier
  - `date` - End of month date
  - `ret_eom` - Bond return with accrued interest
  - `ret_exc` - Excess return over risk-free rate
  - `yield`, `duration`, `convexity` - Risk measures
  - `rating_num` - Numeric rating (1=AAA, 22=D)
  - `yield_spread` - Yield spread over treasury
  - `permno` - CRSP stock identifier (for equity link)

**Other outputs:**
- `trace_daily.pq` - Daily bond prices (Parquet format, efficient storage)
- `factor_regressors.csv` - Market, size, value, credit factors
- `illiq.csv` - Amihud illiquidity measures

## Configuration

All pipeline parameters are centralized in `config/`:

### Main Pipeline: `config/data_paths.jl`

Key constants (automatically loaded via `src/main.jl`):
- `MIN_PRICE_PAIRS = 5` - Minimum prices for illiquidity calculation
- `MAX_DAYS_BETWEEN_PRICES = 7` - Max gap for liquidity measure
- `ROLLING_WINDOW_MONTHS = 36` - Rolling window for signals (3 years)
- `N_PORTFOLIOS = 5` - Number of portfolios for characteristic sorts
- `VAR_QUANTILE = 0.05` - VaR quantile for BBW factors

### Update Pipeline: `config/update_config.jl`

**You must edit this file before running the update pipeline:**

```julia
const UPDATE_DATE = "2025_11_11"      # Date identifier for output directory
const TIMEPERIOD = "_2024_2025"       # Suffix for new TRACE file
const N_WORKERS = 8                   # Parallel workers
const START_YEAR = 2002               # First year of historical data
const END_YEAR = 2024                 # Last year after merge
```

**See [config/README.md](config/README.md) for complete configuration guide.**

## Module Architecture

The pipeline uses a modular architecture defined in `src/main.jl`:

```julia
include("src/main.jl")  # Loads all modules

# Available modules:
DataLoader    # Load TRACE, FISD, WRDS, treasury data
Preprocess    # Bond valuation (R), FISD processing, aggregation
Factors       # Factor construction, portfolio sorts
Pfs           # Performance evaluation, factor regressors
```

**Key functions:**
- `DataLoader.load_trace_intraday()` - Load TRACE data
- `Preprocess.bond_values()` - Compute yields/durations via R
- `Preprocess.agg_daily_trace_to_month()` - Daily → monthly
- `Factors.create_bond_factors()` - Market, size, value factors
- `add_permno()` - Link bonds to CRSP equities

## Performance Benchmarks

**Hardware:** 8-core CPU, 16GB RAM, SSD

| Pipeline | Runtime | Bottleneck |
|----------|---------|------------|
| Main (full) | 6-9 hours | Bond valuation (R BondValuation) |
| Factor creation | 30-60 min | Portfolio sorts |
| Update | 2-4 hours | Bond valuation |
| Error check | 5-10 min | Excel file generation |
| Merge | 5-10 min | I/O operations |

**Optimization tips:**
- Use Julia 1.10+ (~30% faster than 1.8)
- SSD storage recommended
- Adjust `N_WORKERS` in `config/update_config.jl` to match CPU cores
- Bond valuation via R is the main bottleneck (no easy fix)

## Documentation

| Document | Purpose |
|----------|---------|
| [CLAUDE.md](CLAUDE.md) | Developer guide for Claude Code |
| [config/README.md](config/README.md) | Configuration system guide |
| [scripts/README.md](scripts/README.md) | Scripts reference |
| [docs/PIPELINE_WORKFLOW.md](docs/PIPELINE_WORKFLOW.md) | Detailed workflow |
| [docs/DATA_REQUIREMENTS.md](docs/DATA_REQUIREMENTS.md) | Data download instructions |

## Common Issues

### "Package BondValuation not found"
**Solution:** Install in R: `install.packages("BondValuation")`

### RCall cannot find R
**Solution:**
```julia
ENV["R_HOME"] = "C:/Program Files/R/R-4.4.3"  # Adjust to your R installation
using Pkg; Pkg.build("RCall")
```

### Out of memory errors
**Solution:** Reduce `N_WORKERS` in `config/update_config.jl` (try 4 instead of 8)

### "File not found: trace_prices.sas7bdat"
**Solution:** Run SAS scripts in `scripts/download_data/` first to extract data from WRDS

### Extreme returns not flagged
**Solution:** Check `EXTREME_RETURN_THRESHOLD` in `config/update_config.jl` (default: 0.326 = ±32.6%)

### Missing equity links (permno = missing)
**Solution:** Verify both files exist in `data/wrds/`:
- `bondcrsp_link.sas7bdat`
- `../BondEqLink.csv` (in data/ root)

**See [docs/PIPELINE_WORKFLOW.md#troubleshooting](docs/PIPELINE_WORKFLOW.md#troubleshooting) for complete troubleshooting guide.**

## License

Research use only. Contact authors for commercial use.

## Citation

If using this pipeline, please cite:

[Add your paper citation here]

## Data Sources

- **TRACE:** Financial Industry Regulatory Authority (FINRA)
- **FISD:** Mergent Fixed Income Securities Database
- **WRDS:** Wharton Research Data Services
- **GSW:** Federal Reserve Board (Gürkaynak-Sack-Wright parameters)
- **Fama-French Factors:** Kenneth French Data Library
