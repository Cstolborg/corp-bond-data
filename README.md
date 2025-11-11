# Corporate Bond Data Pipeline

A Julia-based pipeline for processing corporate bond market data from TRACE, FISD, and ICE sources, transforming raw trading data into analysis-ready datasets with computed risk measures, returns, and factor signals.

## Quick Start

```bash
# 1. Check data files and download GSW curve
julia --project=. scripts/check_data_files.jl

# 2. Process historical TRACE data (5-9 hours)
julia --project=. scripts/create_datasets.jl

# 3. Create factor returns (30-60 minutes)
julia --project=. scripts/create_factor_data.jl
```

**For incremental updates**, see [Update Pipeline](#update-pipeline) below.

## Project Overview

### Data Sources

- **TRACE** (2002-2024): Intraday and daily corporate bond trading data
- **FISD** (Mergent): Bond characteristics, ratings, amounts outstanding
- **WRDS**: Bond-equity links, Fama-French factors
- **Federal Reserve**: GSW treasury yield curve parameters
- **ICE/Warga** (Optional): Additional/historical bond pricing

### Output Datasets

**Main outputs** (`data/output/`):
- `bonds_full.csv` - Complete bond dataset with returns, risk measures, and factors
- `trace_daily.pq` - Daily bond prices (Parquet format)
- `factor_regressors.csv` - Market, size, value, and credit factors
- `illiq.csv` - Amihud illiquidity measures

**Key variables in `bonds_full.csv`:**
- `ret_eom` - Bond return including accrued interest
- `ret_exc` - Excess return over risk-free rate
- `yield`, `duration`, `convexity` - Risk measures from R BondValuation package
- `rating_num` - Numeric credit rating (1=AAA, 22=D)
- `MV` - Market value (amount outstanding × price)
- `yield_spread` - Yield spread over treasury
- `permno` - Link to CRSP equity data

## Pipeline Architecture

### Main Pipeline (Historical Data)

```
┌─────────────────────────────────────────────────────────┐
│ 1. check_data_files.jl                                  │
│    - Verify required data files present                 │
│    - Auto-download GSW treasury curve                   │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ 2. create_datasets.jl (5-9 hours)                       │
│    - Load TRACE intraday → daily → monthly             │
│    - Compute bond risk measures (parallel, 2-4 hrs)    │
│    - Compute bond returns with accrued interest         │
│    - Add ratings, filters, default returns              │
│    - Compute treasury risk measures (parallel, 2-4 hrs)│
│    OUTPUT: bonds_full.csv                               │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ 3. create_factor_data.jl (30-60 min)                    │
│    - Create factor regressors (market, size, value)     │
│    - Compute BBW factors (VaR, liquidity betas)         │
│    - Add value signals from yield spreads               │
│    - Update equity links (PERMNO/PERMCO)                │
│    OUTPUT: factor_regressors_bbw.csv, updated bonds     │
└─────────────────────────────────────────────────────────┘
```

### Update Pipeline (Incremental Data)

For processing new data (e.g., 2021-2023) and merging with historical datasets:

```bash
# Step 1: Process new data (3-6 hours)
julia --project=. scripts/update_bond_data.jl

# Step 2: Check for extreme returns (15 min)
julia --project=. scripts/check_for_errors.jl
# → Creates Excel files for manual review

# Step 3: Manual review (user task)
# Review Excel files in data/output/update_YYYY_MM_DD/excel_files/
# Mark confirmed errors in spreadsheet

# Step 4: Merge datasets (5 min)
julia --project=. scripts/merge_datasets.jl

# Step 5: Copy merged data to main directory
cp "data/output/update_2025_01_13/bonds_full_2002_2024.csv" "data/output/bonds_full.csv"
cp "data/output/update_2025_01_13/trace_daily_2002_2024.pq" "data/output/trace_daily.pq"

# Step 6: Regenerate factors (45 min)
julia --project=. scripts/create_factor_data.jl
```

**Why the update pipeline?**
- New TRACE data may contain pricing errors requiring manual review
- Error detection exports Excel files showing intraday/daily context
- Allows batch review of all extreme returns before merging

## Project Structure

```
corp-bond-data/
├── src/                      # Core functionality
│   ├── main.jl              # Module definitions
│   ├── data_loader.jl       # Data loading functions
│   ├── preprocessing.jl     # Bond valuation & FISD processing
│   ├── compute_bond_returns.jl  # Return computation
│   ├── factors.jl           # Factor construction
│   ├── portfolios.jl        # Portfolio sorts
│   ├── utils.jl             # Utility functions
│   └── rating_conversions.jl # Rating mappings
├── scripts/                  # Pipeline scripts
│   ├── check_data_files.jl  # Data verification
│   ├── create_datasets.jl   # Main pipeline (TRACE)
│   ├── create_factor_data.jl # Factor construction
│   ├── update_bond_data.jl  # Process incremental data
│   ├── check_for_errors.jl  # Error detection
│   ├── merge_datasets.jl    # Merge old + new data
│   ├── utils_clean_data.jl  # Helper functions
│   └── wrds_get_bond_rets.py # WRDS downloads (Python)
├── config/
│   └── data_paths.jl        # Path configuration
├── data/                     # Data directory
│   ├── trace/               # TRACE SAS files
│   ├── mergent/             # FISD data
│   ├── wrds/                # WRDS downloads
│   └── output/              # Pipeline outputs
├── tests/
│   └── compare_outputs.jl   # Validation tests
└── docs/
    ├── PIPELINE_WORKFLOW.md # Complete workflow guide
    └── DATA_REQUIREMENTS.md # Data download instructions
```

## Installation

### Prerequisites

1. **Julia 1.10+**
2. **R 4.0+** with packages: `BondValuation`, `R.utils`
3. **Python 3.8+** (optional, for WRDS downloads): pandas, numpy, wrds
4. **WRDS Account** (for downloading TRACE and FISD data)

### Setup

```bash
# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Verify R integration
julia --project=. -e 'using RCall; R"library(BondValuation)"'

# If RCall cannot find R, set R_HOME:
julia --project=. -e 'ENV["R_HOME"] = "C:/Program Files/R/R-4.4.3"; using Pkg; Pkg.build("RCall")'
```

### Data Setup

See `docs/DATA_REQUIREMENTS.md` for detailed download instructions.

**Required files:**
- `data/trace/trace_prices.sas7bdat` (500MB-2GB)
- `data/mergent/*.sas7bdat` (FISD issue, ratings, defaults, amount outstanding)
- `data/wrds/bondcrsp_link.sas7bdat`
- `data/wrds/ff_daily.csv`
- `data/BondEqLink.csv`

**Auto-downloaded:**
- `data/output/gsw.csv` (GSW treasury curve from Federal Reserve)

## Module Structure

Code is organized in `src/main.jl` with four main modules:

1. **DataLoader** - Load TRACE, FISD, WRDS data
2. **Preprocess** - Bond valuation, FISD processing, treasury curves
3. **Factors** - Factor construction, portfolio sorts
4. **Pfs** - Factor regressors, performance evaluation

## Scripts Reference

| Script | Purpose | Runtime |
|--------|---------|---------|
| `check_data_files.jl` | Verify data, download GSW | 1 min |
| `create_datasets.jl` | Main pipeline (historical) | 5-9 hrs |
| `create_factor_data.jl` | Factor construction | 30-60 min |
| `update_bond_data.jl` | Process incremental data | 3-6 hrs |
| `check_for_errors.jl` | Error detection & Excel export | 15 min |
| `merge_datasets.jl` | Merge old + new data | 5 min |

## Performance Benchmarks

**Hardware:** 8-core CPU, 16GB RAM, SSD

- **Full pipeline:** 6 hours (bottleneck: bond valuation via R)
- **Factor creation:** 45 minutes
- **Update pipeline:** 4 hours

**Optimization:**
- Use Julia 1.10+ (~30% faster than 1.8)
- SSD storage recommended
- Adjust `N_WORKERS` to match CPU cores

## Documentation

- **[Pipeline Workflow](docs/PIPELINE_WORKFLOW.md)** - Complete step-by-step guide
- **[Data Requirements](docs/DATA_REQUIREMENTS.md)** - Data download instructions
- **[CLAUDE.md](CLAUDE.md)** - Development guide for Claude Code

## Common Issues

### "Package BondValuation not found"
Install in R: `install.packages("BondValuation")`

### Out of memory errors
Reduce `N_WORKERS` in scripts (try 4 instead of 8)

### Extreme returns not flagged
Check `EXTREME_RETURN_THRESHOLD` in `check_for_errors.jl` (default: 32.6%)

### Missing equity links
Verify `data/wrds/bondcrsp_link.sas7bdat` and `data/BondEqLink.csv` exist

See `docs/PIPELINE_WORKFLOW.md#troubleshooting` for complete troubleshooting guide.

## License

Research use only. Contact authors for commercial use.

## Citation

If using this pipeline, please cite:

[Add your paper citation here]
