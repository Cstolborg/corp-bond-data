# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Julia-based pipeline for processing corporate bond market data from TRACE, Warga, and ICE sources. The pipeline transforms raw bond trading data into analysis-ready datasets with computed risk measures, returns, and factor signals.

**Key Data Sources:**
- **TRACE** (2002-2024): Primary intraday and daily trading data
- **FISD** (Mergent): Bond characteristics, ratings, amounts outstanding
- **WRDS**: Bond-equity links, Fama-French factors
- **Treasury/GSW**: Risk-free rates and yield curves
- **ICE/Warga** (Optional): Additional/historical bond pricing

**Runtime:** Full pipeline takes 5-9 hours; bond yield calculations via R's BondValuation package are the main bottleneck (4-8 hours).

## Development Commands

### Environment Setup
```bash
# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Test R integration (required for bond valuation)
julia --project=.
```
```julia
using RCall
R"""
library(BondValuation)
library(R.utils)
"""
```

### Running the Pipeline

**Main pipeline** (TRACE data processing):
```bash
julia --project=. scripts/create_datasets.jl
```

**Update existing datasets** (incremental):
```bash
julia --project=. scripts/update_datasets.jl
```

**Historical/out-of-sample** (Warga data):
```bash
julia --project=. scripts/create_datasets_oos_warga.jl
```

**ICE data preprocessing**:
```bash
julia --project=. scripts/preprocess_new_ice.jl
```

**Create shareable datasets**:
```bash
julia --project=. scripts/data_to_share.jl
```

### Testing

**Run output validation**:
```bash
julia --project=. tests/compare_outputs.jl
```

### WRDS Data Download (Python)
```bash
python scripts/wrds_get_bond_rets.py
```

## Architecture

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

**Key Utilities** (`src/utils.jl`, `src/rating_conversions.jl`):
- Date conversions, rating mappings
- Liquidity measures (Amihud illiquidity)
- Helper functions used across modules

### Pipeline Flow

The main pipeline (`scripts/create_datasets.jl`) follows this sequence:

1. **Load TRACE intraday** → Filter outlier prices
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
10. **Final dataset** → `bonds_full.csv` (value signals, equity links)

### Configuration

**Central config file:** `config/data_paths.jl`
- All data paths (TRACE, WRDS, ICE, output directories)
- Pipeline parameters (date filters, workers, rolling windows)
- Key constants to modify:
  - `TRACE_END_DATE`: Filter TRACE data up to this date
  - `N_WORKERS`: Number of parallel workers for bond valuation
  - `ROLLING_WINDOW_MONTHS`: Default 36 (3 years)
  - `N_PORTFOLIOS`: Number of portfolios for characteristic sorts (default 5)

### Data Directory Structure

```
data/
├── trace/              # TRACE intraday SAS files
├── wrds/               # FISD, bond-equity links, FF factors
├── ice_new/            # ICE data (optional)
├── BondEqLink.csv      # Additional CUSIP-PERMNO mapping
└── output/             # All pipeline outputs
    ├── trace_daily.pq
    ├── trace_monthly.csv
    ├── bonds_full.csv  # Main analysis dataset
    └── ...
```

## Important Technical Details

### Parallel Processing

Risk measure calculations use Julia's `Distributed` module:
```julia
using Distributed
addprocs(8, exeflags="--project")  # Add 8 workers
@everywhere using DataFramesMeta, RCall
@everywhere R"library(BondValuation)"
@everywhere include("../src/main.jl")

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
ENV["R_HOME"] = "C:/Program Files/R/R-4.x.x"  # Windows
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

### Rating System

Ratings converted to 1-22 numeric scale via `src/rating_conversions.jl`:
- 1 = AAA (highest)
- 22 = D (default)
- Functions: `letter_rating_to_numeric()`, `numeric_rating_to_letter()`

### Liquidity Measures

Amihud illiquidity computed in `src/utils.jl`:
- Function: `compute_illiq(trace_daily)`
- Requires minimum price pairs (default: 5)
- Maximum days between prices (default: 7)

## Development Workflow

### Adding New Features

1. **Modify modules in `src/`**: Changes automatically picked up via `include()`
2. **Update config**: Edit `config/data_paths.jl` for new paths/parameters
3. **Test incrementally**: Load modules in REPL and test functions
4. **Run full pipeline**: After testing, run relevant script in `scripts/`

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
3. Integrate into pipeline script

**Modify bond filtering:**
- Edit `Preprocess.filter_bonds!()` in `src/preprocessing.jl`
- Or add filters in specific pipeline stages

**Change parallel processing:**
- Modify `N_WORKERS` and `BOND_VALUES_SPLITS` in `config/data_paths.jl`
- Optimal: match number of physical CPU cores

## Data Requirements

See `docs/DATA_REQUIREMENTS.md` for detailed data download instructions. Key files:

**Required:**
- `data/trace/trace_prices.sas7bdat` (500MB-2GB)
- `data/wrds/bondcrsp_link.sas7bdat`
- `data/wrds/ff_daily.csv`
- `data/output/gsw.csv` (Treasury curve parameters)
- `data/BondEqLink.csv`

**Optional:**
- `data/ice_new/ICE_GI00.csv` (for ICE pipeline)
- Warga data (for historical/OOS analysis)

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

- **Julia 1.9+**
- **R 4.0+** with packages: BondValuation, R.utils
- **Python 3.8+** (optional, for WRDS downloads): pandas, numpy, wrds

Julia packages (from Project.toml):
- DataFrames, DataFramesMeta, CSV, Parquet
- RCall (R integration)
- SASLib (read WRDS .sas7bdat files)
- Distributed (parallel processing)
- GLM, StatsBase, Statistics
- ShiftedArrays, Roots, Dates
