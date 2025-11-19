"""
    test_bonds_subset.jl

Test script to verify that data/data_to_share/bonds_subset.csv matches
the expected output in tests/bonds_full_test.csv.

This test ensures that the bonds_subset.csv file (the shareable dataset)
contains the correct values for all columns present in it, compared to
the full test dataset.

Usage:
    julia --project=. tests/test_bonds_subset.jl

Test logic:
    1. Load both datasets
    2. Check that date ranges match
    3. Verify that all columns in bonds_subset.csv exist in bonds_full_test.csv
    4. Join on (cusip, date) and compare values for all columns in bonds_subset
    5. Report any mismatches
"""

using DataFramesMeta, Dates, CSV

# Load rating conversion dictionary
include("../src/rating_conversions.jl")

println("\n" * "="^80)
println("Testing bonds_subset.csv Against Expected Output")
println("="^80 * "\n")

# ============================================================================
# LOAD DATA
# ============================================================================

println("[1/4] Loading datasets...")

test_file = "tests/bonds_full_test.csv"
subset_file = "data/data_to_share/bonds_subset.csv"

if !isfile(test_file)
    error("Test file not found: $test_file")
end

if !isfile(subset_file)
    error("Subset file not found: $subset_file")
end

bonds_test = CSV.read(test_file, DataFrame)
transform!(bonds_test, :rating_num=>ByRow(x->rating_conversion[round(x)])=>:rating_group)
@subset!(bonds_test, year.(:date).<=2023) # Limit to 2023 and earlier for testing

bonds_subset = CSV.read(subset_file, DataFrame)
@subset!(bonds_subset, year.(:date).<=2023) # Limit to 2023 and earlier for testing

println("✓ Loaded test dataset: $(nrow(bonds_test)) rows")
println("✓ Loaded subset dataset: $(nrow(bonds_subset)) rows")

# ============================================================================
# CHECK DATE RANGES
# ============================================================================

println("\n[2/4] Checking date ranges...")

test_dates = extrema(bonds_test.date)
subset_dates = extrema(bonds_subset.date)

println("  Test dataset dates: $(test_dates[1]) to $(test_dates[2])")
println("  Subset dataset dates: $(subset_dates[1]) to $(subset_dates[2])")

if test_dates == subset_dates
    println("✓ Date ranges match!")
else
    println("✗ WARNING: Date ranges differ!")
    println("  Expected: $(test_dates[1]) to $(test_dates[2])")
    println("  Actual:   $(subset_dates[1]) to $(subset_dates[2])")
end

# ============================================================================
# CHECK COLUMN PRESENCE
# ============================================================================

println("\n[3/4] Checking columns...")

subset_cols = names(bonds_subset)
test_cols = names(bonds_test)

# Find columns that exist in both datasets (these will be compared)
common_cols = intersect(subset_cols, test_cols)
subset_only_cols = setdiff(subset_cols, test_cols)

if length(subset_only_cols) > 0
    println("  ℹ Columns in subset but not in test file (will be skipped):")
    println("    $(join(subset_only_cols, ", "))")
end

println("✓ Found $(length(common_cols)) common columns to compare")

# ============================================================================
# COMPARE VALUES
# ============================================================================

println("\n[4/4] Comparing values...")

# Join datasets on cusip and date (only use common columns from test)
# Note: common_cols already includes :cusip and :date, so we just select those
merged = innerjoin(
    select(bonds_test, common_cols...),
    bonds_subset,
    on=[:cusip, :date],
    makeunique=true
)

pct_matched = 100 * nrow(merged) / nrow(bonds_test)
println("  Matched observations: $(nrow(merged)) / $(nrow(bonds_test)) ($(round(pct_matched, digits=1))%)")

if nrow(merged) == 0
    error("✗ No matching (cusip, date) pairs found between datasets!")
end

if nrow(merged) < nrow(bonds_subset)
    missing_count = nrow(bonds_subset) - nrow(merged)
    println("  ⚠ WARNING: $missing_count observations in subset not found in test dataset")
end

# Compare each column
mismatches = DataFrame(
    column = String[],
    n_mismatches = Int[],
    n_compared = Int[],
    pct_mismatch = Float64[]
)

# Debug: Print merged column names
println("\n  DEBUG: Columns in merged dataset:")
println("  $(join(names(merged), ", "))")
println()

for col in common_cols
    if col in ["cusip", "date"]
        continue  # Skip join keys
    end

    # After innerjoin with makeunique=true:
    # - Columns from left table (bonds_test) keep original names
    # - Columns from right table (bonds_subset) get _1 suffix if there's a conflict
    # Since we selected only common_cols from left, all common columns will have duplicates
    col_test = Symbol(col)  # From bonds_test (left)
    col_subset = Symbol(col * "_1")  # From bonds_subset (right)

    # Check if both columns exist in merged dataset
    # Note: Only columns in common_cols should have _1 suffix
    if !(String(col_test) in names(merged))
        # Column not in left table - this shouldn't happen for common_cols
        continue
    end

    if !(String(col_subset) in names(merged))
        # Column doesn't have _1 suffix - means it's only in right table
        # This shouldn't happen for columns in common_cols, so skip
        continue
    end

    # Compare values, handling missing values
    col_test_vals = merged[!, col_test]
    col_subset_vals = merged[!, col_subset]

    # Count non-missing observations in both
    both_present = .!ismissing.(col_test_vals) .& .!ismissing.(col_subset_vals)
    n_compared = sum(both_present)

    if n_compared == 0
        println("  ⚠ Column $col: No non-missing values to compare")
        continue
    end

    # Compare values where both are present
    if eltype(col_test_vals) <: AbstractFloat || eltype(col_subset_vals) <: AbstractFloat
        # For floating point, use approximate equality (3 significant digits)
        # rtol=1e-3 means 0.1% relative tolerance
        matches = isapprox.(col_test_vals[both_present], col_subset_vals[both_present], rtol=1e-3, atol=1e-8)
    else
        # For other types, use exact equality
        matches = col_test_vals[both_present] .== col_subset_vals[both_present]
    end

    n_mismatches = sum(.!matches)
    pct_mismatch = 100 * n_mismatches / n_compared

    push!(mismatches, (
        column = col,
        n_mismatches = n_mismatches,
        n_compared = n_compared,
        pct_mismatch = pct_mismatch
    ))
end

# ============================================================================
# REPORT RESULTS
# ============================================================================

println("\n" * "="^80)
println("Test Results")
println("="^80 * "\n")



# Check if we actually compared any columns
if nrow(mismatches) == 0
    println("✗ WARNING: No columns were compared!")
    println("\nPossible reasons:")
    println("  - All common columns are join keys (cusip, date)")
    println("  - Columns from subset not found in merged dataset with expected naming")
    println("\nDebug info:")
    println("  Common columns: $(join(common_cols, ", "))")
    exit(1)
end

total_mismatches = sum(mismatches.n_mismatches)
columns_with_mismatches = sum(mismatches.n_mismatches .> 0)

if total_mismatches == 0
    println("✓ SUCCESS: All values match!")
    println("\nSummary:")
    println("  Total columns compared: $(nrow(mismatches))")
    println("  Total observations compared: $(nrow(merged))")
    println("  Mismatches found: 0")
else
    println("✗ FAILURE: Found mismatches in $columns_with_mismatches columns")
    println("\nColumns with mismatches:")

    mismatched_cols = @subset(mismatches, :n_mismatches .> 0)
    sort!(mismatched_cols, :n_mismatches, rev=true)

    for row in eachrow(mismatched_cols)
        println("  $(row.column): $(row.n_mismatches) / $(row.n_compared) ($(round(row.pct_mismatch, digits=2))%)")
    end

    println("\nSummary:")
    println("  Total columns compared: $(nrow(mismatches))")
    println("  Columns with mismatches: $columns_with_mismatches")
    println("  Total mismatches: $total_mismatches")

    # Show first few mismatches for debugging
    println("\n" * "="^80)
    println("First Mismatch Details (for debugging)")
    println("="^80)

    first_mismatch_col = mismatched_cols[1, :column]
    col_test = Symbol(first_mismatch_col)
    col_subset = Symbol(first_mismatch_col * "_1")

    if eltype(merged[!, col_test]) <: AbstractFloat
        mismatch_rows = .!isapprox.(merged[!, col_test], merged[!, col_subset], rtol=1e-3, atol=1e-8, nans=false)
    else
        mismatch_rows = merged[!, col_test] .!= merged[!, col_subset]
    end

    # Handle missing values in comparison
    mismatch_rows = replace(mismatch_rows, missing => false)

    first_mismatches = merged[mismatch_rows, :][1:min(5, sum(mismatch_rows)), :]

    println("\nColumn: $first_mismatch_col")
    println("Sample mismatches (showing first 5):\n")

    for row in eachrow(first_mismatches)
        println("  CUSIP: $(row.cusip), Date: $(row.date)")
        println("    Expected: $(row[col_test])")
        println("    Actual:   $(row[col_subset])")
    end

    error("\n✗ Test failed: Values do not match")
end

println()



# ============================================================================
# HELPER FUNCTION: Inspect mismatches for a specific column
# ============================================================================

"""
    inspect_column_mismatches(col_name::String)

Show all rows where a specific column doesn't match between test and subset datasets.
Includes cusip, date, and the values from both datasets.

Example:
    inspect_column_mismatches("price_eom")
"""
function inspect_column_mismatches(col_name::String)
    if !(col_name in common_cols)
        println("✗ Column '$col_name' not in common columns")
        println("Available columns: $(join(common_cols, ", "))")
        return nothing
    end

    col_test = Symbol(col_name)
    col_subset = Symbol(col_name * "_1")

    # Check if columns exist
    if !(String(col_test) in names(merged)) || !(String(col_subset) in names(merged))
        println("✗ Column '$col_name' not found in merged dataset")
        return nothing
    end

    # Find mismatches
    col_test_vals = merged[!, col_test]
    col_subset_vals = merged[!, col_subset]

    # Compare values
    if eltype(col_test_vals) <: AbstractFloat || eltype(col_subset_vals) <: AbstractFloat
        # For floating point, use approximate equality (3 significant digits)
        # rtol=1e-3 means 0.1% relative tolerance
        mismatch_rows = .!isapprox.(col_test_vals, col_subset_vals, rtol=1e-3, atol=1e-8, nans=true)
    else
        # For other types, use exact equality
        mismatch_rows = col_test_vals .!= col_subset_vals
    end

    # Handle missing values
    mismatch_rows = replace(mismatch_rows, missing => false)

    n_mismatches = sum(mismatch_rows)

    if n_mismatches == 0
        println("✓ Column '$col_name': No mismatches found!")
        return nothing
    end

    println("\n" * "="^80)
    println("Column: $col_name")
    println("="^80)
    println("Total mismatches: $n_mismatches / $(nrow(merged)) rows\n")

    # Select mismatched rows with cusip, date, and both versions of the column
    mismatches_df = merged[mismatch_rows, [:cusip, :date, col_test, col_subset]]
    rename!(mismatches_df, col_test => Symbol(col_name * "_test"), col_subset => Symbol(col_name * "_subset"))

    # Add a difference column for numeric types
    # Handle Union{T, Missing} types by checking the non-missing type
    test_type = eltype(col_test_vals)
    subset_type = eltype(col_subset_vals)

    # Check if the non-missing type is numeric
    is_numeric = false
    if test_type <: Number || subset_type <: Number
        is_numeric = true
    elseif test_type isa Union
        # For Union types, check if any component is Number (excluding Missing)
        for T in Base.uniontypes(test_type)
            if T <: Number
                is_numeric = true
                break
            end
        end
    end

    if is_numeric
        transform!(mismatches_df,
                   [Symbol(col_name * "_test"), Symbol(col_name * "_subset")] =>
                   ByRow((x, y) -> ismissing(x) || ismissing(y) ? missing : x - y) =>
                   :difference)
    end

    return mismatches_df
end

# Usage example (commented out):
mismatches_price_eom = inspect_column_mismatches("value") |> x->@subset(x, abs.(:difference).>=0.01) |> x->sort(x, :difference)
# CSV.write("mismatches_price_eom.csv", mismatches_price_eom)

@subset(fisd.amt_out, :cusip.=="413627BE9")