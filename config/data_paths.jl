"""
    data_paths.jl

Centralized configuration file for all data paths and pipeline parameters.
Modify these paths according to your data location.
"""

using Dates

# ============================================================================
# BASE PATHS
# ============================================================================

const PROJECT_ROOT = dirname(@__DIR__)
const DATA_DIR = joinpath(PROJECT_ROOT, "data")
const OUTPUT_DIR = joinpath(DATA_DIR, "output")

# ============================================================================
# INPUT DATA PATHS
# ============================================================================

# TRACE Data
const TRACE_DIR = joinpath(DATA_DIR, "trace")
const TRACE_INTRADAY_FILE = joinpath(TRACE_DIR, "trace_prices.sas7bdat")

# WRDS Data
const WRDS_DIR = joinpath(DATA_DIR, "wrds")
const FISD_DIR = WRDS_DIR  # FISD data location
const BONDCRSP_LINK = joinpath(WRDS_DIR, "bondcrsp_link.sas7bdat")
const FF_DAILY = joinpath(WRDS_DIR, "ff_daily.csv")

# ICE Data
const ICE_DIR = joinpath(DATA_DIR, "ice_new")
const ICE_GI00 = joinpath(ICE_DIR, "ICE_GI00.csv")

# Treasury/GSW Data
const GSW_FILE = joinpath(OUTPUT_DIR, "gsw.csv")

# Bond-Equity Link
const BOND_EQ_LINK = joinpath(DATA_DIR, "BondEqLink.csv")

# ============================================================================
# OUTPUT DATA PATHS
# ============================================================================

# Daily/Monthly TRACE
const TRACE_DAILY = joinpath(OUTPUT_DIR, "trace_daily.pq")
const TRACE_MONTHLY = joinpath(OUTPUT_DIR, "trace_monthly.csv")
const ILLIQ = joinpath(OUTPUT_DIR, "illiq.csv")

# Risk Measures
const RISK_MEASURES = joinpath(OUTPUT_DIR, "risk_measures_trace.csv")
const TREASURY_RISK_MEASURES = joinpath(OUTPUT_DIR, "treasury_risk_measures_trace.csv")
const ERROR_CUSIPS = joinpath(OUTPUT_DIR, "error_cusips.csv")

# Date/Coupon Vectors
const DATE_VECTORS = joinpath(OUTPUT_DIR, "date_vectors_trace.csv")
const DATES_TRACE = joinpath(OUTPUT_DIR, "dates_trace.csv")

# Main Bond Datasets
const BONDS = joinpath(OUTPUT_DIR, "bonds.csv")
const BONDS_FULL = joinpath(OUTPUT_DIR, "bonds_full.csv")

# Factor Data
const FACTOR_REGRESSORS = joinpath(OUTPUT_DIR, "factor_regressors.csv")
const FACTOR_REGRESSORS_BBW = joinpath(OUTPUT_DIR, "factor_regressors_bbw.csv")
const BOND_FACTORS = joinpath(OUTPUT_DIR, "bond_factors.csv")

# Signals
const SIGNALS = joinpath(OUTPUT_DIR, "signals_warga_trace.csv")
const FSIGNALS = joinpath(OUTPUT_DIR, "fsignal_warga_trace.csv")

# Historical/OOS Data
const WARGA_ICE = joinpath(OUTPUT_DIR, "warga_ice.csv")
const WARGA_ICE_FULL = joinpath(OUTPUT_DIR, "warga_ice_full.csv")
const WARGA_ICE_TRACE = joinpath(OUTPUT_DIR, "warga_ice_trace.csv")

# ICE Processed
const ICE_MONTHLY = joinpath(ICE_DIR, "ice_monthly.csv")
const ICE_ILLIQ = joinpath(ICE_DIR, "illiq.csv")

# Shareable Data Output
const SHARE_DIR = joinpath(DATA_DIR, "data_to_share")
const BOND_RETURNS_SHARE = joinpath(SHARE_DIR, "bond_returns.csv")
const FIRM_RETURNS_SHARE = joinpath(SHARE_DIR, "firm_returns.csv")
const BOND_EQ_LINK_SHARE = joinpath(SHARE_DIR, "bond_equity_link.csv")

# ============================================================================
# PIPELINE CONFIGURATION PARAMETERS
# ============================================================================

# Date Filters
const TRACE_END_DATE = Date(2024, 4, 30)  # Filter TRACE data up to this date
const TRACE_MONTH_END_DATE = Date(2023, 12, 31)  # Monthly data end date

# Bond Filtering
const VALID_COUPON_TYPES = ["F", "Z"]  # Fixed and Zero coupon only
const MIN_RATING = 1  # Minimum rating (1-22 scale)
const MAX_RATING = 22  # Maximum rating
const MIN_MATURITY_YEARS = 1.0  # Minimum time to maturity (years)

# Liquidity Calculation
const MIN_PRICE_PAIRS = 5  # Minimum price pairs for illiquidity calculation
const MAX_DAYS_BETWEEN_PRICES = 7  # Max days between price observations

# Parallel Processing
const N_WORKERS = 8  # Number of parallel workers for bond_values()
const BOND_VALUES_SPLITS = 8  # Number of data splits for parallel processing

# Rolling Window Parameters
const ROLLING_WINDOW_MONTHS = 36  # Rolling window for signal computation
const VAR_QUANTILE = 0.05  # VaR quantile level

# Factor Construction
const N_PORTFOLIOS = 5  # Number of portfolios for characteristic sorts

# Update Pipeline (for update_datasets.jl)
const UPDATE_TIME_PERIOD = "_2021_2023"  # Time period identifier for updates
const UPDATE_PATH = joinpath(TRACE_DIR, "update 13-01-2025/")  # Update data path

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

"""
    ensure_share_dir()

Create shareable data directory if it doesn't exist.
"""
function ensure_share_dir()
    if !isdir(SHARE_DIR)
        mkpath(SHARE_DIR)
        @info "Created share directory: $SHARE_DIR"
    end
end

# Create output directories on load
ensure_output_dir()

# Print configuration summary
@info """
Data Pipeline Configuration Loaded
===================================
Project Root: $PROJECT_ROOT
Data Directory: $DATA_DIR
Output Directory: $OUTPUT_DIR
TRACE End Date: $TRACE_END_DATE
Parallel Workers: $N_WORKERS
"""
