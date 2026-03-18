"""
    update_config.jl

Main configuration file for the corporate bond data pipeline.

Used by:
- scripts/main/create_datasets.jl (main pipeline)
- scripts/main/check_for_errors.jl (error checking)

USAGE: Simply include this file at the top of each script:
    include("../../config/update_config.jl")

Configuration is automatically applied to all scripts.
"""

# ============================================================================
# PROCESSING PARAMETERS
# ============================================================================

# Auto-detect optimal number of workers (half of CPU cores + 1)
# You can override this by setting N_WORKERS manually
const N_WORKERS = let
    n_cores = Sys.CPU_THREADS
    max(1, div(n_cores, 2) + 1)  # Half of cores + 1, minimum 1
end

# ============================================================================
# ERROR CHECKING CONFIGURATION
# ============================================================================

const UPDATE_DATE = "2025_11_11"      # Date identifier for Excel output directory
const LAST_DATE = Date(2023, 12, 31)  # Last date of data to check

# Error detection parameters (for check_for_errors.jl)
const EXTREME_RETURN_THRESHOLD = 0.326  # 32.6% absolute return threshold
const N_MONTHS_BACK = 4               # Months of data before extreme return
const N_MONTHS_FORWARD = 2            # Months of data after extreme return
