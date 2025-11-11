"""
    merge_datasets.jl

Merge cleaned incremental bond data with historical datasets.

This script combines the new bond data (after manual error review) with the
existing historical dataset to create an extended time series.

Usage:
    julia --project=. scripts/merge_datasets.jl

Prerequisites:
    1. Run update_bond_data.jl to create incremental data
    2. Run check_for_errors.jl to identify extreme returns
    3. Manually review and classify errors in Excel files
    4. (Optional) Create error exclusion list

Configuration:
    Edit UPDATE_DATE and HISTORICAL_DATA_PATH below

Input files:
    - data/output/update_YYYY_MM_DD/bonds_full.csv (new data)
    - data/output/bonds_full.csv (historical data)
    - data/output/update_YYYY_MM_DD/trace_daily_PERIOD.pq (new daily data)
    - data/output/trace_daily.pq (historical daily data)
    - data/output/update_YYYY_MM_DD/illiq_PERIOD.csv (new illiquidity)
    - data/output/illiq.csv (historical illiquidity)
    - (Optional) Error exclusion file from manual review

Output files:
    - data/output/update_YYYY_MM_DD/trace_daily_FULL.pq
    - data/output/update_YYYY_MM_DD/bonds_full_FULL.csv

Next step: Run create_factor_data.jl to regenerate factors on combined dataset
"""

using DataFramesMeta, Dates, CSV, Parquet
using XLSX

include("../src/main.jl")
include("utils_clean_data.jl")

# ============================================================================
# CONFIGURATION
# ============================================================================

UPDATE_DATE = "2025_01_13"       # Update directory name
TIMEPERIOD = "_2021_2023"        # TRACE file suffix for new data
START_YEAR = 2002                # First year of historical data
END_YEAR = 2024                  # Last year after merge

# Paths
UPDATE_PATH = "data/output/update_$(UPDATE_DATE)/"
HISTORICAL_PATH = "data/output/"  # Where old data lives
OUTPUT_SUFFIX = "$(START_YEAR)_$(END_YEAR)"

# Optional: Path to Excel file with confirmed errors to exclude
# Set to nothing if not using error exclusion
ERROR_FILE = nothing  # e.g., UPDATE_PATH*"confirmed_errors.xlsx"

println("\n" * "="^80)
println("Merging Historical and Incremental Bond Data")
println("="^80)
println("Historical data: $HISTORICAL_PATH")
println("New data: $UPDATE_PATH")
println("Output suffix: $OUTPUT_SUFFIX")
println("="^80 * "\n")

# ============================================================================
# STEP 1: LOAD ERROR EXCLUSIONS (OPTIONAL)
# ============================================================================

if ERROR_FILE !== nothing && isfile(ERROR_FILE)
    println("[1/5] Loading error exclusions from manual review...")

    df_errors = DataFrame(XLSX.readtable(ERROR_FILE, "errors", "A:B"))
    df_errors.cusip = string.(df_errors.cusip)
    df_errors.date = lastdayofmonth.(Date.(df_errors.date))

    println("✓ Loaded $(nrow(df_errors)) confirmed errors to exclude")
else
    println("[1/5] No error exclusion file specified - proceeding with all data")
    df_errors = DataFrame(cusip=String[], date=Date[])
end

# ============================================================================
# STEP 2: MERGE DAILY TRACE DATA
# ============================================================================

println("\n[2/5] Merging daily TRACE data...")

# Load historical daily data
trace_daily_old = DataFrame(read_parquet(HISTORICAL_PATH*"trace_daily.pq")) |> year_month_day_to_date!
println("  Historical: $(nrow(trace_daily_old)) observations ($(extrema(trace_daily_old.date)))")

# Load new daily data
trace_daily_new = DataFrame(read_parquet(UPDATE_PATH*"trace_daily"*TIMEPERIOD*".pq")) |> year_month_day_to_date!
println("  New: $(nrow(trace_daily_new)) observations ($(extrema(trace_daily_new.date)))")

# Combine and deduplicate
trace_daily = vcat(trace_daily_old, trace_daily_new) |>
    x->unique(x, [:cusip, :date]) |>
    x->sort(x, [:cusip, :date])

println("✓ Combined daily data: $(nrow(trace_daily)) observations")

# Save combined daily data
date_to_year_month_day!(trace_daily)
write_parquet(UPDATE_PATH*"trace_daily_$(OUTPUT_SUFFIX).pq", trace_daily)
year_month_day_to_date!(trace_daily)
println("✓ Saved: $(UPDATE_PATH)trace_daily_$(OUTPUT_SUFFIX).pq")

# ============================================================================
# STEP 3: MERGE BOND RETURN DATA
# ============================================================================

println("\n[3/5] Merging bond return data...")

# Load historical bond data
bonds_old = CSV.read(HISTORICAL_PATH*"bonds_full.csv", DataFrame)
println("  Historical: $(nrow(bonds_old)) observations ($(extrema(bonds_old.date)))")

# Load new bond data
bonds_new = CSV.read(UPDATE_PATH*"bonds_full.csv", DataFrame)
println("  New: $(nrow(bonds_new)) observations ($(extrema(bonds_new.date)))")

# Apply error exclusions if provided
if nrow(df_errors) > 0
    println("\n  Excluding $(nrow(df_errors)) confirmed error observations...")
    bonds_new = antijoin(bonds_new, df_errors, on=[:cusip, :date])
    println("  ✓ New data after exclusions: $(nrow(bonds_new)) observations")
end

# Add rating conversion to new data
transform!(bonds_new, :rating_num=>ByRow(x->rating_conversion[round(x)])=>:rating)

# Combine and deduplicate
bonds = vcat(bonds_old, bonds_new)
unique!(bonds, [:cusip, :date])
sort!(bonds, [:cusip, :date])

println("✓ Combined bond data: $(nrow(bonds)) observations")
println("  Date range: $(minimum(bonds.date)) to $(maximum(bonds.date))")

# ============================================================================
# STEP 4: MERGE ILLIQUIDITY DATA
# ============================================================================

println("\n[4/5] Merging illiquidity measures...")

# Load historical illiquidity
illiq_old = CSV.read(HISTORICAL_PATH*"illiq.csv", DataFrame)
println("  Historical: $(nrow(illiq_old)) observations")

# Load new illiquidity
illiq_new = CSV.read(UPDATE_PATH*"illiq"*TIMEPERIOD*".csv", DataFrame)
println("  New: $(nrow(illiq_new)) observations")

# Combine and deduplicate
illiq = vcat(illiq_old, illiq_new) |>
    x->unique(x, [:cusip, :eom]) |>
    x->sort(x, [:cusip, :eom])

println("✓ Combined illiquidity: $(nrow(illiq)) observations")

# Add illiquidity to bond data
leftjoin!(bonds, illiq, on=[:cusip, :date=>:eom])
println("✓ Illiquidity measures added to bond dataset")

# ============================================================================
# STEP 5: UPDATE EQUITY LINKS AND SAVE
# ============================================================================

println("\n[5/5] Updating equity links (PERMNO/PERMCO)...")

# Remove old equity links
select!(bonds, Not([:permno, :permco]))

# Add fresh equity links
bonds = add_permno(bonds; link_period="trace")

n_with_permno = nrow(dropmissing(bonds, :permno))
pct_linked = round(100 * n_with_permno / nrow(bonds), digits=1)
println("✓ Equity links updated: $(n_with_permno)/$(nrow(bonds)) bonds ($(pct_linked)%)")

# Save final merged dataset
CSV.write(UPDATE_PATH*"bonds_full_$(OUTPUT_SUFFIX).csv", bonds)
println("✓ Saved: $(UPDATE_PATH)bonds_full_$(OUTPUT_SUFFIX).csv")

# ============================================================================
# SUMMARY
# ============================================================================

println("\n" * "="^80)
println("Data Merge Complete!")
println("="^80)
println("\nFinal dataset summary:")
println("  Total observations: $(nrow(bonds))")
println("  Unique bonds: $(length(unique(bonds.cusip)))")
println("  Date range: $(minimum(bonds.date)) to $(maximum(bonds.date))")
println("  With equity links: $(n_with_permno) ($(pct_linked)%)")

if nrow(df_errors) > 0
    println("\n  Excluded errors: $(nrow(df_errors))")
end

println("\nOutput files:")
println("  - $(UPDATE_PATH)trace_daily_$(OUTPUT_SUFFIX).pq")
println("  - $(UPDATE_PATH)bonds_full_$(OUTPUT_SUFFIX).csv")

println("\n" * "="^80)
println("Next Step: Factor Construction")
println("="^80)
println("Run the following to create factor returns on the combined dataset:")
println("  # First, copy merged data to main output directory")
println("  cp $(UPDATE_PATH)bonds_full_$(OUTPUT_SUFFIX).csv data/output/bonds_full.csv")
println("  cp $(UPDATE_PATH)trace_daily_$(OUTPUT_SUFFIX).pq data/output/trace_daily.pq")
println()
println("  # Then regenerate factors")
println("  julia --project=. scripts/create_factor_data.jl")
println()
