"""
    data_paths.jl

Centralized configuration for data paths and key pipeline parameters.
This file is loaded by src/main.jl and provides constants used across modules.
"""

using Dates

# ============================================================================
# BASE PATHS
# ============================================================================

const PROJECT_ROOT = dirname(@__DIR__)
const DATA_DIR = joinpath(PROJECT_ROOT, "data")
const OUTPUT_DIR = joinpath(DATA_DIR, "output")

# ============================================================================
# INPUT DATA DIRECTORIES
# ============================================================================

const WRDS_DIR = joinpath(DATA_DIR, "wrds")  # All WRDS data (TRACE, FISD, links, etc.)
const ICE_DIR = joinpath(DATA_DIR, "ice_new")

# For backward compatibility (all now point to WRDS_DIR)
const TRACE_DIR = WRDS_DIR
const FISD_DIR = WRDS_DIR

# ============================================================================
# COMMONLY USED INPUT FILES
# ============================================================================

# TRACE
const TRACE_INTRADAY_FILE = joinpath(WRDS_DIR, "trace_prices.sas7bdat")

# WRDS/FISD
const BONDCRSP_LINK = joinpath(WRDS_DIR, "bondcrsp_link.sas7bdat")
const FF_DAILY = joinpath(WRDS_DIR, "ff_daily.csv")

# Treasury
const GSW_FILE = joinpath(OUTPUT_DIR, "gsw.csv")

# Bond-Equity Links
const BOND_EQ_LINK = joinpath(DATA_DIR, "BondEqLink.csv")

# ============================================================================
# PIPELINE PARAMETERS
# ============================================================================

# Bond Filtering
const VALID_COUPON_TYPES = ["F", "Z"]  # Fixed and Zero coupon only
const MIN_MATURITY_YEARS = 1.0  # Minimum time to maturity (years)

# Liquidity Calculation (Amihud illiquidity)
const MIN_PRICE_PAIRS = 5  # Minimum price pairs for covariance calculation
const MAX_DAYS_BETWEEN_PRICES = 7  # Maximum days between consecutive prices

# Factor Construction
const N_PORTFOLIOS = 5  # Number of portfolios for characteristic sorts
const ROLLING_WINDOW_MONTHS = 36  # Rolling window for signal computation (3 years)
const VAR_QUANTILE = 0.05  # VaR quantile level for BBW factors

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

"""
    ensure_output_dir()

Create output directory if it doesn't exist.
"""
function ensure_output_dir()
    if !isdir(OUTPUT_DIR)
        mkpath(OUTPUT_DIR)
        @info "Created output directory: $OUTPUT_DIR"
    end
end

# Create output directory on load
ensure_output_dir()
