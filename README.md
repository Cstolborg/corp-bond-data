# Corporate Bond Factors: Replication and Data Pipeline

This repository contains the data processing pipeline code for the research paper:

**"Corporate Bond Factors: Replication Failures and a New Framework"**
Available at: [SSRN](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4586652)

The data is published by WRDS.
- Bond-level data: [WRDS Corporate Bond Factors: Bonds](https://wrds-www.wharton.upenn.edu/pages/get-data/contributed-data-forms/corporate-bond-factors-bonds/)
- Firm-level data: [WRDS Corporate Bond Factors: Firms](https://wrds-www.wharton.upenn.edu/pages/get-data/contributed-data-forms/corporate-bond-factors-firms/)

## Overview

This project provides a Julia-based pipeline for processing U.S. corporate bond market data from TRACE (2002-2024), transforming raw trading records into analysis-ready datasets with computed risk measures, returns, and factor signals.

The pipeline produces two primary output datasets:
- **`data/data_to_share/bonds.csv`** - Bond-level dataset (individual bonds)
- **`data/data_to_share/firms.csv`** - Firm-level dataset (bonds aggregated by issuer)

**If you use this code or data in your research, please cite our paper.**

## Quick Start

### Prerequisites

- **Julia 1.10+** - Main pipeline language (packages installed via Project.toml, see Installation below)
- **Python 3.9+** with pandas, pyarrow and fastparquet
- **R 4.0+** with packages: BondValuation, R.utils - Bond yield/duration calculations
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
# Verify data files
julia --project=. scripts/main/check_data_files.jl

# Process TRACE and compute bond risk measures
julia --project=. scripts/main/create_datasets.jl

# Outputs:
# - data/output/bonds_full.csv       # Complete bond-level dataset (internal use)
# - data/output/firms_full.csv       # Complete firm-level dataset (internal use)
# - data/data_to_share/bonds.csv     # Bond subset for end users
# - data/data_to_share/firms.csv     # Firm subset for end users
```

### Error Checking Workflow

After running the main pipeline, check for extreme returns and data quality issues:

```bash
# 1. Check for extreme returns
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

Firm-month panel, aggregating all bonds per issuer into a representative firm. Includes the same core variables as the individual bond dataset but represents each firm's aggregate bond portfolio.

### Primary Output Datasets (data/data_to_share/)

**These are the main datasets for end users:**
- `data/data_to_share/bonds.csv` - Key bond variables (subset for analysis)
- `data/data_to_share/firms.csv` - Key firm variables (subset for analysis)

Complete datasets with all variables are in `data/output/` for internal use.

## License

This code is provided for academic research purposes. Please cite our paper if you use this code or data. For commercial use, contact the authors.

## Contact

For questions about the code or data, please open an issue on GitHub or contact the authors via the SSRN paper page.
