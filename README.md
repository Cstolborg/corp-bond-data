# Corporate Bond Factors: Replication and Data Pipeline

This repository contains the data processing pipeline and analysis code for the research paper:

**"Corporate Bond Factors: Replication Failures and a New Framework"**
Available at: https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4586652

## Overview

This project provides a comprehensive Julia-based pipeline for processing U.S. corporate bond market data from TRACE (2002-2024), transforming raw trading records into analysis-ready datasets with computed risk measures, returns, and factor signals.

**If you use this code or data in your research, please cite our paper.**

## Key Features

- **Complete Data Pipeline**: Processes TRACE intraday data → daily prices → monthly returns → risk measures → factor portfolios
- **Rigorous Bond Valuation**: Uses R's BondValuation package for yield and duration calculations
- **Quality Controls**: Automated outlier detection, manual review workflow for extreme returns
- **Factor Construction**: Market, size, value, credit risk, VaR, and liquidity factors
- **Firm-Level Aggregation**: Duration-weighted aggregation from bond-level to firm-level
- **Transparent & Reproducible**: Open source code with detailed documentation

## Quick Start

### Prerequisites

- **Julia 1.10+** - Main pipeline language
- **Python 3.9+** with pandas, pyarrow and fastparquet
- **R 4.0+** with BondValuation package - Bond yield/duration calculations
- **WRDS Account** - Required for TRACE and FISD data access
- **Hardware**: 32+ GB RAM, SSD recommended

### Installation

```bash
# Clone repository
git clone <your-repo-url>
cd corp-bond-data

# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Verify R integration
julia --project=. -e 'using RCall; R"library(BondValuation)"'
```

### Basic Usage

```bash
# 1. Download data from WRDS (see Data Download section)

# 2. Verify data files
julia --project=. scripts/main/check_data_files.jl

# 3. Run main pipeline (5-9 hours)
julia --project=. scripts/main/create_datasets.jl

# Primary outputs: data/data_to_share/bonds.csv and data/data_to_share/firms.csv
# Also creates: data/output/bonds_full.csv, data/output/firms_full.csv (complete datasets)
```

## Data Sources

This pipeline integrates data from multiple sources:

| Source | Description | Access |
|--------|-------------|--------|
| **TRACE** | U.S. corporate bond intraday transactions (2002-2024) | WRDS/FINRA |
| **FISD** | Mergent Fixed Income Securities Database (bond characteristics) | WRDS |
| **CRSP** | Bond-equity linking tables (CUSIP to PERMNO) | WRDS |
| **Fama-French** | Daily equity factor returns and risk-free rates | WRDS/Kenneth French Library |
| **GSW** | Treasury yield curve parameters | Federal Reserve (auto-downloaded) |

### Data Download Instructions

**Step 1: Run SAS scripts on WRDS SAS Studio**

The `scripts/download_data/` directory contains SAS programs to extract data:

1. Navigate to WRDS SAS Studio (wrds-www.wharton.upenn.edu)
2. Upload and run these scripts:
   - `trace_filter.sas` → `trace_prices.sas7bdat` (500MB-2GB)
   - `get_fisd.sas` → 5 FISD files (characteristics, ratings, defaults, amounts)
   - `stocks.sas` → `bondcrsp_link.sas7bdat` and `stocks.csv`
3. Download output files to your local machine

**Step 2: Organize files**

Place ALL downloaded `.sas7bdat` and `.csv` files in `data/wrds/`:

```
data/
├── wrds/                          # All WRDS data files
│   ├── trace_prices.sas7bdat     # TRACE intraday
│   ├── fisd_issue.sas7bdat       # Bond characteristics
│   ├── fisd_ratings.sas7bdat     # Credit ratings
│   ├── fisd_defaults.sas7bdat    # Default dates
│   ├── fisd_amt_out.sas7bdat     # Amount outstanding
│   ├── fisd_amt_out_hist.sas7bdat # Amount outstanding (historical)
│   ├── bondcrsp_link.sas7bdat    # Bond-equity links
│   ├── stocks.csv                 # Equity returns
│   └── ff_daily.csv              # Fama-French factors
│
└── BondEqLink.csv                 # Additional links (provided separately)
```

**Step 3: Verify**

```bash
julia --project=. scripts/main/check_data_files.jl
```

**See CLAUDE.md for detailed pipeline instructions and developer guide.**

## Pipeline Overview

### Main Pipeline (Historical Data)

Process the complete historical dataset (2002-2024):

```bash
# Verify data files (1 min)
julia --project=. scripts/main/check_data_files.jl

# Process TRACE and compute bond risk measures (5-9 hours)
julia --project=. scripts/main/create_datasets.jl

# Outputs:
# - data/output/bonds_full.csv       # Complete bond-level dataset (internal use)
# - data/output/firms_full.csv       # Complete firm-level dataset (internal use)
# - data/data_to_share/bonds.csv     # Bond subset for end users
# - data/data_to_share/firms.csv     # Firm subset for end users
```

**Runtime:** 5-9 hours (bond valuation via R is the main bottleneck)

### Error Checking Workflow

After running the main pipeline, check for extreme returns and data quality issues:

```bash
# 1. Check for extreme returns (5-10 min)
julia --project=. scripts/main/check_for_errors.jl

# 2. Manually review Excel files in data/error_checks/excel_YYYY_MM_DD/
#    - Check flagged returns
#    - Verify if pricing errors or real market events

# 3. Add reviewed errors to data/error_checks/errors.xlsx
#    - Format: Excel file with sheet 'TRACE_error' containing columns 'cusip', 'trade_date'
#    - Already-reviewed returns will be excluded on next run

# 4. Re-run check_for_errors.jl to check for additional issues
#    (reviewed returns are automatically excluded)
```

**Note:** The script checks the entire dataset but excludes returns already documented in `errors.xlsx`.

## Output Datasets

### Bond-Level Dataset: `data/output/bonds_full.csv`

One row per bond-month observation (~2M+ rows):

| Column | Description |
|--------|-------------|
| `cusip` | 9-character bond identifier |
| `permno` | CRSP permanent number (equity link) |
| `date` | End-of-month date |
| `name` | Issuer name |
| `price_eom` | End-of-month clean price |
| `ret_eom` | Return with accrued interest |
| `ret_exc` | Excess return over risk-free rate |
| `ret_texc_lead` | Treasury-adjusted excess return (credit premium) |
| `yield` | Yield to maturity |
| `yield_spread` | Yield spread over risk-free rate |
| `duration` | Modified duration |
| `tmt` | Time to maturity (years) |
| `rating_group` | Letter rating (AAA, AA, A, BBB, BB, B, CCC, CC, C, D) |
| `rating_num` | Numeric rating (1=AAA, 22=D) |
| `MV` | Market value |
| `amount_outstanding` | Face value outstanding |
| `value` | Value signal (yield spread residual) |
| `bond_age_pct` | Bond age as percentage of life |
| `ret_eq` | Corresponding equity return |

### Firm-Level Dataset: `data/output/firms.csv`

Duration-weighted aggregation of all bonds per firm (~200K+ rows):

- All bond-level columns, aggregated using duration weights
- Useful for firm-level credit risk analysis

### Primary Output Datasets (data/data_to_share/)

**These are the main datasets for end users:**
- `data/data_to_share/bonds.csv` - Key bond variables (subset for analysis)
- `data/data_to_share/firms.csv` - Key firm variables (subset for analysis)

Complete datasets with all variables are in `data/output/` for internal use.

## Project Structure

```
corp-bond-data/
├── config/                      # Configuration
│   └── update_config.jl        # Main configuration file (N_WORKERS, dates, thresholds)
│
├── src/                         # Core Julia modules
│   ├── main.jl                 # Module loader
│   ├── data_loader.jl          # TRACE/FISD/WRDS loading
│   ├── preprocessing.jl        # Bond valuation via R
│   ├── compute_bond_returns.jl # Return calculations
│   ├── factors.jl              # Factor construction
│   ├── portfolios.jl           # Portfolio sorts
│   ├── utils.jl                # Utility functions
│   └── rating_conversions.jl   # Rating mappings
│
├── scripts/                     # Pipeline scripts
│   ├── download_data/          # Data download (SAS/Python - RUN FIRST)
│   │   ├── trace_filter.sas   # Extract TRACE data
│   │   ├── get_fisd.sas       # Extract FISD data
│   │   ├── stocks.sas         # Extract bond-equity links
│   │   └── wrds_get_bond_rets.py  # Optional WRDS downloads
│   │
│   ├── main/                   # Main pipeline scripts
│   │   ├── check_data_files.jl     # Verify data files
│   │   ├── create_datasets.jl      # Main pipeline (5-9 hours)
│   │   ├── check_for_errors.jl     # Error detection workflow
│   │   └── utils_clean_data.jl     # Cleaning utilities
│   │
│
├── data/                       # Data directory
│   ├── wrds/                  # All WRDS data files (from SAS Studio)
│   ├── data_to_share/         # PRIMARY OUTPUTS (end user datasets)
│   │   ├── bonds.csv          # Bond-level dataset
│   │   └── firms.csv          # Firm-level dataset
│   ├── output/                # Pipeline outputs (internal use)
│   ├── error_checks/          # Error review workflow
│   │   ├── errors.xlsx        # Reviewed errors
│   │   └── excel_YYYY_MM_DD/  # Excel files for review
│   └── BondEqLink.csv         # Additional bond-equity links
│
├── tests/                      # Test files
│   ├── test_bonds_subset.jl   # Dataset validation tests
│   └── bonds_full_test.csv    # Reference dataset
│
├── .gitignore                  # Git ignore rules
├── Project.toml                # Julia dependencies
├── Manifest.toml               # Julia dependency versions
├── README.md                   # This file - project overview
└── CLAUDE.md                   # Developer guide for Claude Code
```

## Technical Details

### Bond Valuation

The pipeline uses R's **BondValuation** package to compute:
- Yield to maturity (YTM)
- Modified duration
- Convexity
- Treasury-equivalent prices and yields

This ensures accurate pricing and risk measures consistent with bond market conventions.

### Data Quality Controls

1. **Reversal Flag Detection**: Filters outlier prices before daily aggregation
2. **Extreme Return Detection**: Flags returns exceeding ±32.6% for manual review
3. **Excel Review Workflow**: Creates detailed workbooks showing intraday/daily data around extreme returns
4. **Manual Correction**: Supports error exclusion lists for confirmed data errors

### Parallel Processing

Bond valuation is parallelized using Julia's `Distributed` module:
- **Auto-configured:** `N_WORKERS` automatically set to half of CPU cores + 1
  - Example: 16-core system → 9 workers
  - Override in `config/update_config.jl` if needed
- Each worker loads R's BondValuation independently

### Factor Construction

The pipeline implements multiple factor models:
- **Market Factor**: Value-weighted bond market return
- **Size Factor**: Small vs. large bonds (by market value)
- **Value Factor**: High vs. low yield spreads
- **Credit Factor**: Investment grade vs. high yield
- **BBW Factors**: VaR and liquidity risk (Bai, Bali & Wen, 2019)

## Performance

**Hardware:** 8-core CPU, 16GB RAM, SSD

| Task | Runtime | Notes |
|------|---------|-------|
| Main pipeline | 5-9 hours | Bond valuation is bottleneck |
| Error checking | 5-10 min | Excel file generation |
| Data merging | 5-10 min | I/O operations |

**Optimization tips:**
- Use Julia 1.10+ for best performance
- SSD storage recommended
- Adjust `N_WORKERS` to match CPU cores

## Citation

If you use this code or data in your research, please cite:

```
[Add formatted citation here]

Available at: https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4586652
```

## Documentation

| Document | Purpose |
|----------|---------|
| [README.md](README.md) | This file - project overview and quick start |
| [CLAUDE.md](CLAUDE.md) | Comprehensive developer guide and pipeline workflow |

## Troubleshooting

### Common Issues

**"Package BondValuation not found"**
```r
install.packages("BondValuation")
install.packages("R.utils")
```

**RCall cannot find R**
```julia
ENV["R_HOME"] = "C:/Program Files/R/R-4.4.3"  # Adjust path
using Pkg; Pkg.build("RCall")
```

**Out of memory errors**
- Reduce `N_WORKERS` in `config/update_config.jl` (try 4 instead of 8)

**"File not found: trace_prices.sas7bdat"**
- Run SAS scripts in `scripts/download_data/` on WRDS SAS Studio first

See [CLAUDE.md](CLAUDE.md) for complete pipeline documentation and troubleshooting guide.

## License

This code is provided for academic research purposes. Please cite our paper if you use this code or data. For commercial use, contact the authors.

## Contact

For questions about the code or data, please open an issue on GitHub or contact the authors via the SSRN paper page.

---

**Research Paper:** https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4586652
