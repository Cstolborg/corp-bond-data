"""
    merge_datasets.jl

Apply manual error corrections to the main bond dataset.

This script applies corrections identified during manual Excel review back into
the main bond dataset. It excludes confirmed error observations and recalculates
affected metrics.

Workflow:
    1. Run create_datasets.jl (processes full updated TRACE file)
    2. Run check_for_errors.jl (identifies extreme returns, creates Excel files)
    3. Manually review Excel files and document errors
    4. Run this script to apply corrections

Usage:
    julia --project=. scripts/update/merge_datasets.jl

Prerequisites:
    1. Run create_datasets.jl to create main dataset
    2. Run check_for_errors.jl to identify potential errors
    3. Manually review Excel files in data/error_checks/excel_YYYY_MM_DD/
    4. Create error exclusion file (Excel or CSV) with columns: cusip, date

Configuration:
    Edit config/update_config.jl to set:
    - UPDATE_DATE: Date identifier for error check directory
    - ERROR_FILE: Path to error exclusion file (optional)

Input files:
    - data/output/bonds_full.csv (main dataset)
    - data/output/firms.csv (firm-level data)
    - data/output/trace_daily.pq (daily prices)
    - (Optional) ERROR_FILE: Excel/CSV with cusip and date columns for errors to exclude

Output files (UPDATES main dataset):
    - data/output/bonds_full.csv (with errors removed)
    - data/output/firms.csv (recalculated)
    - data/data_to_share/bonds_full.csv (copy)
    - data/data_to_share/firms.csv (copy)

Note: If no ERROR_FILE is specified, the script will still run but won't exclude
      any observations. This is useful for recalculating firms after manual edits.
"""

using DataFramesMeta, Dates, CSV, Parquet
using XLSX

include("../../src/main.jl")
include("../utils/utils_clean_data.jl")
include("../../config/update_config.jl")

println("\n" * "="^80)
println("Applying Manual Error Corrections to Main Dataset")
println("="^80)
println("Update date: $UPDATE_DATE")
println("Main dataset: data/output/bonds_full.csv")
if ERROR_FILE !== nothing
    println("Error file: $ERROR_FILE")
else
    println("Error file: None (no exclusions will be applied)")
end
println("="^80 * "\n")

# ============================================================================
# STEP 1: LOAD ERROR EXCLUSIONS (OPTIONAL)
# ============================================================================

if ERROR_FILE !== nothing && isfile(ERROR_FILE)
    println("[1/4] Loading error exclusions from manual review...")

    # Determine file type and load accordingly
    if endswith(ERROR_FILE, ".xlsx")
        df_errors = DataFrame(XLSX.readtable(ERROR_FILE, "errors", "A:B"))
    elseif endswith(ERROR_FILE, ".csv")
        df_errors = CSV.read(ERROR_FILE, DataFrame)
    else
        error("ERROR_FILE must be .xlsx or .csv format")
    end

    # Standardize column names and types
    rename!(df_errors, lowercase.(names(df_errors)))
    df_errors.cusip = string.(df_errors.cusip)
    df_errors.date = Date.(df_errors.date)

    # Convert to end-of-month dates if needed
    if any(day.(df_errors.date) .!= daysinmonth.(df_errors.date))
        df_errors.date = lastdayofmonth.(df_errors.date)
        println("  ⚠ Converted dates to end-of-month")
    end

    println("✓ Loaded $(nrow(df_errors)) confirmed errors to exclude")
    println("  CUSIPs affected: $(length(unique(df_errors.cusip)))")
else
    if ERROR_FILE !== nothing
        println("[1/4] Error file specified but not found: $ERROR_FILE")
        println("  Proceeding without error exclusions")
    else
        println("[1/4] No error exclusion file specified")
        println("  Proceeding without error exclusions")
    end
    df_errors = DataFrame(cusip=String[], date=Date[])
end

# ============================================================================
# STEP 2: LOAD AND CLEAN BOND DATA
# ============================================================================

println("\n[2/4] Loading main bond dataset...")

bonds = CSV.read("data/output/bonds_full.csv", DataFrame)
n_before = nrow(bonds)
date_range_before = extrema(bonds.date)

println("✓ Loaded bond data")
println("  Observations: $(n_before)")
println("  Date range: $(date_range_before[1]) to $(date_range_before[2])")
println("  Unique bonds: $(length(unique(bonds.cusip)))")

# Apply error exclusions if provided
if nrow(df_errors) > 0
    println("\n  Applying error exclusions...")

    # Anti-join to remove error observations
    bonds_before_excl = nrow(bonds)
    bonds = antijoin(bonds, df_errors, on=[:cusip, :date])
    n_excluded = bonds_before_excl - nrow(bonds)

    println("  ✓ Excluded $(n_excluded) error observations")
    println("  ✓ Remaining: $(nrow(bonds)) observations")

    if n_excluded != nrow(df_errors)
        println("  ⚠ Warning: Expected to exclude $(nrow(df_errors)) but only excluded $(n_excluded)")
        println("    This may mean some errors were already removed or dates don't match")
    end
else
    println("\n  No error exclusions to apply")
end

# ============================================================================
# STEP 3: RECALCULATE FIRM-LEVEL RETURNS
# ============================================================================

println("\n[3/4] Recalculating firm-level aggregated returns...")

# Define columns to aggregate at firm level
numcols = [:price_eom, :ret_eom, :ret_exc, :ret_exc_lead, :ret_texc_lead, :ret_eq,
           :value, :illiq, :rating_num, :MV, :amount_outstanding, :MV_lag, :MV_lead,
           :duration, :tmt, :convexity, :bond_age_pct, :bm, :yield_spread, :yield]

# Compute firm returns (duration-adjusted aggregation by PERMNO)
firms = Preprocess.compute_firm_ret(bonds, numcols; firm_id=:permno, duration_adjust=true)

println("✓ Firm-level returns calculated")
println("  Firm-month observations: $(nrow(firms))")
println("  Unique firms (PERMNO): $(length(unique(firms.permno)))")

# ============================================================================
# STEP 4: SAVE UPDATED DATASETS
# ============================================================================

println("\n[4/4] Saving updated datasets...")

# Save to main output directory
CSV.write("data/output/bonds_full.csv", bonds)
println("✓ Saved: data/output/bonds_full.csv")

CSV.write("data/output/firms.csv", firms)
println("✓ Saved: data/output/firms.csv")

# Also save to data_to_share directory
CSV.write("data/data_to_share/bonds_full.csv", bonds)
CSV.write("data/data_to_share/firms.csv", firms)
println("✓ Saved copies to: data/data_to_share/")

# ============================================================================
# SUMMARY
# ============================================================================

println("\n" * "="^80)
println("Error Correction Complete!")
println("="^80)
println("\nDataset summary:")
println("  Observations before: $(n_before)")
println("  Observations after: $(nrow(bonds))")
if nrow(df_errors) > 0
    println("  Excluded errors: $(n_before - nrow(bonds))")
end
println("  Unique bonds: $(length(unique(bonds.cusip)))")
println("  Date range: $(minimum(bonds.date)) to $(maximum(bonds.date))")
println("\nFirm-level data:")
println("  Firm-month observations: $(nrow(firms))")
println("  Unique firms: $(length(unique(firms.permno)))")

println("\nOutput files updated:")
println("  - data/output/bonds_full.csv")
println("  - data/output/firms.csv")
println("  - data/data_to_share/bonds_full.csv")
println("  - data/data_to_share/firms.csv")

if nrow(df_errors) == 0
    println("\n" * "="^80)
    println("NOTE: No errors were excluded")
    println("="^80)
    println("If you identified errors in manual review, create an error file with:")
    println("  - Column 1: cusip (9-character bond identifier)")
    println("  - Column 2: date (YYYY-MM-DD or Excel date format)")
    println("Then update ERROR_FILE in config/update_config.jl and re-run this script")
end

println()
