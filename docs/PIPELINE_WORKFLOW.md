# Corporate Bond Data Pipeline Workflow

This document describes the complete workflow for processing corporate bond trading data from TRACE, FISD, and other sources.

## Table of Contents

1. [Initial Setup](#initial-setup)
2. [Main Pipeline (Historical Data)](#main-pipeline-historical-data)
3. [Update Pipeline (Incremental Data)](#update-pipeline-incremental-data)
4. [Pipeline Architecture](#pipeline-architecture)
5. [Troubleshooting](#troubleshooting)

---

## Initial Setup

### Prerequisites

- **Julia 1.10+** with all dependencies installed
- **R 4.0+** with packages: `BondValuation`, `R.utils`
- **Python 3.8+** (optional, for WRDS downloads)
- **Data access**: WRDS subscription for TRACE, FISD, and factor data

### Installation

```bash
# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Verify R integration
julia --project=. -e 'using RCall; R"library(BondValuation)"'
```

### Data Download

See `DATA_REQUIREMENTS.md` for detailed download instructions. Required files:

- TRACE intraday data (`data/trace/trace_prices.sas7bdat`)
- FISD files (`data/mergent/*.sas7bdat`)
- WRDS files (`data/wrds/*.sas7bdat`, `data/wrds/ff_daily.csv`)
- Bond-equity link (`data/BondEqLink.csv`)

---

## Main Pipeline (Historical Data)

Process complete historical TRACE data (typically 2002-2020) to create the base dataset.

### Step 1: Check Data Files

Verify all required data files are present and download GSW treasury curve data:

```bash
julia --project=. scripts/check_data_files.jl
```

**Output:**
- ✓/✗ for each required file
- Auto-downloads `data/output/gsw.csv` if missing

### Step 2: Create Main Datasets

Process TRACE data through the full pipeline:

```bash
julia --project=. scripts/create_datasets.jl
```

**Runtime:** 5-9 hours (bond valuation is the bottleneck)

**Output files** (in `data/output/`):
- `trace_daily.pq` - Daily bond prices
- `trace_monthly.csv` - Monthly bond prices
- `illiq.csv` - Amihud illiquidity measures
- `risk_measures_trace.csv` - Bond yields, duration, convexity
- `date_vectors_trace.csv` - Temporal features
- `dates_trace.csv` - Coupon payment schedules
- `bonds.csv` - Bond returns with characteristics
- `treasury_risk_measures_trace.csv` - Treasury-equivalent risk measures
- `bonds_full.csv` - Complete bond dataset with treasury returns

### Step 3: Create Factor Data

Generate factor returns and signals:

```bash
julia --project=. scripts/create_factor_data.jl
```

**Runtime:** 30-60 minutes

**Output files:**
- `data/output/factor_regressors.csv` - Market, size, value factors
- `data/output/factor_regressors_bbw.csv` - BBW-style factors (VaR, liquidity)
- `data/output/bonds_full.csv` - Updated with value signals and equity links

---

## Update Pipeline (Incremental Data)

Process new TRACE data (e.g., 2021-2023) and merge with historical datasets.

### Step 1: Process New Data

Create bond datasets for the incremental period:

```bash
julia --project=. scripts/update_bond_data.jl
```

**Configuration:** Edit `TIMEPERIOD` and `UPDATE_DATE` in script
- `TIMEPERIOD = "_2021_2023"` - Suffix for TRACE file
- `UPDATE_DATE = "2025_01_13"` - Output directory name

**Runtime:** 3-6 hours

**Output:** All intermediate files in `data/output/update_YYYY_MM_DD/`

### Step 2: Check for Errors

Identify extreme returns and create Excel files for manual review:

```bash
julia --project=. scripts/check_for_errors.jl
```

**Configuration:** Must match `UPDATE_DATE` from Step 1

**Output:**
- Excel files in `data/output/update_YYYY_MM_DD/excel_files/`
- One `.xlsx` per bond with extreme returns (±32.6%)
- Each file contains 4 sheets:
  - `intraday_1cusip` - Intraday data for the flagged bond
  - `intraday_others` - Intraday data for all issuer bonds (6-digit CUSIP)
  - `daily_1cusip` - Daily data for the flagged bond
  - `daily_others` - Daily data for all issuer bonds

**Manual Review Process:**

1. Open Excel files in `excel_files/` directory
2. For each flagged return (where `marked_obs_ind = TRUE`):
   - Check if price is realistic vs. previous/next trades
   - Compare with other bonds from same issuer
   - Classify as:
     - **Real trade**: Legitimate market movement
     - **Data error**: Obvious pricing mistake, trade reversal, etc.
3. Record confirmed errors in a tracking spreadsheet:
   - Columns: `cusip`, `date`
   - Save as `data/output/update_YYYY_MM_DD/confirmed_errors.xlsx`

### Step 3: Merge Datasets

Combine cleaned new data with historical dataset:

```bash
julia --project=. scripts/merge_datasets.jl
```

**Configuration:**
- Set `ERROR_FILE` to path of confirmed errors (or `nothing` to skip exclusions)
- Verify `UPDATE_DATE`, `TIMEPERIOD`, `START_YEAR`, `END_YEAR`

**Output:**
- `data/output/update_YYYY_MM_DD/trace_daily_2002_2024.pq`
- `data/output/update_YYYY_MM_DD/bonds_full_2002_2024.csv`

### Step 4: Copy to Main Directory

Replace old data with merged dataset:

```bash
# Windows PowerShell
cp "data/output/update_2025_01_13/bonds_full_2002_2024.csv" "data/output/bonds_full.csv"
cp "data/output/update_2025_01_13/trace_daily_2002_2024.pq" "data/output/trace_daily.pq"
```

### Step 5: Regenerate Factors

Create factor returns on the extended dataset:

```bash
julia --project=. scripts/create_factor_data.jl
```

This updates `bonds_full.csv` with fresh value signals and factor regressors.

---

## Pipeline Architecture

### Script Dependencies

```
check_data_files.jl (optional)
           ↓
create_datasets.jl ──→ create_factor_data.jl


UPDATE PIPELINE:

update_bond_data.jl ──→ check_for_errors.jl ──→ merge_datasets.jl ──→ create_factor_data.jl
                              ↓
                    (Manual Excel review)
```

### Module Structure

All scripts use modules defined in `src/main.jl`:

- **DataLoader**: Load TRACE, FISD, WRDS data
- **Preprocess**: Bond valuation, FISD processing, treasury curves
- **Factors**: Factor construction, portfolio sorts
- **Pfs**: Factor regressors, performance evaluation

Helper functions in `scripts/utils_clean_data.jl`:
- `compute_illiq()` - Amihud illiquidity
- `add_temporal_features()` - Time to maturity, coupons
- `compute_reversal_flags!()` - Outlier detection

### Key Configuration Files

- `config/data_paths.jl` - All data paths and pipeline parameters
  - `TRACE_END_DATE` - Filter TRACE data up to this date
  - `N_WORKERS` - Parallel workers for bond valuation (default: 8)
  - `ROLLING_WINDOW_MONTHS` - Window for rolling signals (default: 36)

### Data Flow

**Main Pipeline:**
```
TRACE intraday (500MB-2GB)
    ↓ Value-weighted aggregation
Daily prices (trace_daily.pq)
    ↓ End-of-month selection
Monthly prices (trace_monthly.csv)
    ↓ Merge with FISD + R BondValuation
Risk measures (risk_measures_trace.csv) [2-4 hours]
    ↓ Compute returns with accrued interest
Bond returns (bonds.csv)
    ↓ Add treasury-equivalent pricing
Treasury risk (treasury_risk_measures_trace.csv) [2-4 hours]
    ↓ Compute treasury returns
Final dataset (bonds_full.csv)
    ↓ Factor construction
Factor returns (factor_regressors.csv)
```

**Update Pipeline:**
```
New TRACE data
    ↓ update_bond_data.jl
Incremental dataset (bonds_full.csv in update dir)
    ↓ check_for_errors.jl
Excel files for review
    ↓ Manual classification
Confirmed errors list
    ↓ merge_datasets.jl (excludes errors)
Combined dataset (bonds_full_2002_2024.csv)
    ↓ Copy to main dir + create_factor_data.jl
Updated factors
```

---

## Troubleshooting

### RCall Cannot Find BondValuation

**Problem:** `Error: package 'BondValuation' not found`

**Solution:**
1. Install in R/RStudio: `install.packages("BondValuation")`
2. Verify in Julia: `using RCall; R"library(BondValuation)"`
3. If still fails, rebuild RCall:
   ```julia
   ENV["R_HOME"] = "C:/Program Files/R/R-4.4.3"  # Your R path
   using Pkg; Pkg.build("RCall")
   ```

### Out of Memory Errors

**Problem:** Julia crashes during bond valuation

**Solution:**
1. Reduce `N_WORKERS` in script (try 4 instead of 8)
2. Process data in chunks:
   ```julia
   # In create_datasets.jl, subset by date
   @subset!(trace_intraday, :date .< Date(2015, 1, 1))  # First half
   ```
3. Increase system swap space

### Extreme Returns Not Being Flagged

**Problem:** `check_for_errors.jl` finds no extreme returns

**Solution:**
1. Check `EXTREME_RETURN_THRESHOLD` setting (default: 0.326 = 32.6%)
2. Verify date range: script only checks new data period
3. Ensure `bonds.csv` was created successfully in Step 1

### Excel Files Too Large to Open

**Problem:** Excel crashes when opening files for issuers with many bonds

**Solution:**
- Script auto-detects and creates separate CSV files when >10 bonds per issuer
- Check subdirectories in `excel_files/CUSIP/` for CSV output
- Use `res_intraday.csv` and `res_daily.csv` instead

### Missing Equity Links (PERMNO)

**Problem:** Most bonds show `missing` for `permno` column

**Solution:**
1. Verify `data/wrds/bondcrsp_link.sas7bdat` exists
2. Verify `data/BondEqLink.csv` exists
3. Check date coverage - links may not exist for all periods
4. Expected link rate: 60-80% of bonds

### Bond Valuation Taking Too Long

**Problem:** Risk measure computation exceeds 8 hours

**Solution:**
1. Verify using Julia 1.10+ (1.8 is slower)
2. Check CPU usage - should use all cores
3. Reduce data size for testing:
   ```julia
   df = df[1:10000, :]  # Test with subset first
   ```
4. Consider using SSD instead of HDD for data storage

---

## Performance Benchmarks

**Hardware:** 8-core CPU, 16GB RAM, SSD storage

| Script                  | Runtime | Bottleneck              |
|-------------------------|---------|-------------------------|
| check_data_files.jl     | 1 min   | GSW download            |
| create_datasets.jl      | 6 hrs   | Bond valuation (R)      |
| create_factor_data.jl   | 45 min  | Rolling signals         |
| update_bond_data.jl     | 4 hrs   | Bond valuation (R)      |
| check_for_errors.jl     | 15 min  | Excel file generation   |
| merge_datasets.jl       | 5 min   | File I/O                |

**Total (first run):** ~7 hours
**Total (update):** ~5 hours

---

## Questions?

See `README.md` for general project overview and `DATA_REQUIREMENTS.md` for data sources.

For issues, check: `docs/TROUBLESHOOTING.md`
