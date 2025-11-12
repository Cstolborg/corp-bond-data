# Configuration Files

This directory contains centralized configuration for the bond data pipeline.

## Files

### `data_paths.jl`
**Loaded by:** `src/main.jl` (automatically available in all modules)

Contains:
- Base directory paths (PROJECT_ROOT, DATA_DIR, OUTPUT_DIR)
- Input data directories (TRACE_DIR, WRDS_DIR, etc.)
- Commonly used file paths (BONDCRSP_LINK, FF_DAILY, GSW_FILE, etc.)
- Pipeline parameters (MIN_PRICE_PAIRS, ROLLING_WINDOW_MONTHS, VAR_QUANTILE, etc.)

**Usage:**
```julia
include("src/main.jl")  # Automatically loads config

# Constants are available globally
println(OUTPUT_DIR)  # "data/output"
println(MIN_PRICE_PAIRS)  # 5
```

### `update_config.jl`
**Loaded by:** Update pipeline scripts (`update_bond_data.jl`, `check_for_errors.jl`, `merge_datasets.jl`)

Contains configuration constants for the update pipeline. Simply include at the top of each script.

**Usage:**
```julia
include("../config/update_config.jl")

# All constants are now available:
println(UPDATE_DATE)     # "2025_11_11"
println(TIMEPERIOD)      # "_2024_2025"
println(PATH)            # "data/output/update_2025_11_11/"
println(N_WORKERS)       # 8
```

**To run a new update:**
1. Edit `config/update_config.jl` - change UPDATE_DATE and TIMEPERIOD
2. Run all three scripts - they automatically use the new configuration
3. No need to modify the scripts themselves!

## Benefits of This Structure

### ✅ Single Source of Truth
Update configuration in ONE file (`update_config.jl`), not three separate scripts.

### ✅ No Code Changes
Scripts never need modification - just update the config file.

### ✅ Consistent Configuration
All three update scripts use identical parameters by design.

### ✅ Clear Documentation
All parameters documented in one place with sensible defaults.

## Configuration Parameters

### `update_config.jl` Parameters

**Required (must update for each run):**
- `UPDATE_DATE` - Date identifier for output directory (e.g., "2025_11_11")
- `TIMEPERIOD` - Suffix for TRACE file (e.g., "_2024_2025", "" for full period)

**Processing parameters:**
- `N_WORKERS` - Number of parallel workers for bond valuation (default: 8)

**Error detection:**
- `EXTREME_RETURN_THRESHOLD` - Return threshold for error detection (default: 0.326 = ±32.6%)
- `N_MONTHS_BACK` - Months before extreme return to show in Excel (default: 4)
- `N_MONTHS_FORWARD` - Months after extreme return to show in Excel (default: 2)

**Merge parameters:**
- `START_YEAR` - First year of historical data (default: 2002)
- `END_YEAR` - Last year after merge (default: 2024)
- `ERROR_FILE` - Path to confirmed errors file, or `nothing` (default: nothing)

**Auto-generated (don't modify):**
- `PATH` - Output directory (e.g., "data/output/update_2025_11_11/")
- `EXCEL_PATH` - Excel file output directory
- `OUTPUT_SUFFIX` - Merged dataset suffix (e.g., "2002_2024")

## Typical Workflow

### Step 1: Configure Update
Edit `config/update_config.jl`:
```julia
const UPDATE_DATE = "2025_11_11"      # Today's date
const TIMEPERIOD = "_2024_2025"       # Match your TRACE file suffix
```

### Step 2: Run Pipeline
```bash
# Process new data
julia --project=. scripts/update_bond_data.jl

# Check for errors
julia --project=. scripts/check_for_errors.jl

# (Manual review of Excel files)

# Merge datasets
julia --project=. scripts/merge_datasets.jl
```

All scripts automatically use the configuration from `update_config.jl` - no need to edit them!

## See Also

- [Pipeline Workflow](../docs/PIPELINE_WORKFLOW.md) - Complete workflow documentation
- [Data Requirements](../docs/DATA_REQUIREMENTS.md) - Required data files
