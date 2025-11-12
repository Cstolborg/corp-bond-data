"""
    update_config.jl

Configuration for the update pipeline scripts:
- update_bond_data.jl
- check_for_errors.jl
- merge_datasets.jl

USAGE: Simply include this file at the top of each script:
    include("../config/update_config.jl")

Then modify the constants below to match your update period.
All three scripts will automatically use the same configuration.
"""

# ============================================================================
# UPDATE CONFIGURATION - MODIFY THESE VALUES
# ============================================================================

const UPDATE_DATE = "2025_11_11"      # Date identifier for output directory
const TIMEPERIOD = "_2024_2025"       # Suffix for TRACE file (use "" for full period)

# ============================================================================
# PROCESSING PARAMETERS
# ============================================================================

const N_WORKERS = 8                   # Parallel workers for bond valuation

# Error detection parameters (for check_for_errors.jl)
const EXTREME_RETURN_THRESHOLD = 0.326  # 32.6% absolute return threshold
const N_MONTHS_BACK = 4               # Months of data before extreme return
const N_MONTHS_FORWARD = 2            # Months of data after extreme return

# Merge parameters (for merge_datasets.jl)
const START_YEAR = 2002               # First year of historical data
const END_YEAR = 2024                 # Last year after merge
const ERROR_FILE = nothing            # Path to confirmed errors (or nothing)
# Example: ERROR_FILE = "data/output/update_$(UPDATE_DATE)/confirmed_errors.xlsx"

# ============================================================================
# AUTO-GENERATED PATHS (don't modify)
# ============================================================================

const PATH = "data/output/update_$(UPDATE_DATE)/"
const EXCEL_PATH = PATH * "excel_files/"
const OUTPUT_SUFFIX = "$(START_YEAR)_$(END_YEAR)"

# Create directories if they don't exist
!isdir(PATH) && mkpath(PATH)
!isdir(EXCEL_PATH) && mkpath(EXCEL_PATH)
