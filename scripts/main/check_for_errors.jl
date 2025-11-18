"""
    check_for_errors.jl

Detect extreme bond returns in the full dataset and create Excel files for manual review.

This script identifies bonds with extreme returns (absolute value >= threshold) across
the entire dataset, excluding returns that have already been manually reviewed.

Workflow:
    1. Run create_datasets.jl (processes full updated TRACE file)
    2. Run this script to check for extreme returns
    3. Manually review Excel files and add reviewed errors to data/error_checks/errors.xlsx
    4. Re-run this script to check for additional errors (already-reviewed returns are excluded)

Usage:
    julia --project=. scripts/main/check_for_errors.jl

Configuration:
    Edit config/update_config.jl to set:
    - EXTREME_RETURN_THRESHOLD: Return threshold (default 0.326 = ±32.6%)
    - N_MONTHS_BACK, N_MONTHS_FORWARD: Data window for Excel files

Input files:
    - data/output/bonds_full.csv (from create_datasets.jl)
    - data/output/trace_daily.pq (from create_datasets.jl)
    - data/wrds/trace_prices.sas7bdat (intraday data)
    - data/error_checks/errors.xlsx (already-reviewed errors, optional)

Output:
    - Excel files in data/error_checks/excel_YYYY_MM_DD/
    - One .xlsx file per bond with extreme returns (not yet reviewed)
    - Each file contains 4 sheets: intraday/daily data for the bond and its issuer
    - bond_returns_to_check.csv: List of all extreme returns

Next step:
    1. Manually review Excel files
    2. Add reviewed errors to data/error_checks/errors.xlsx in "TRACE_error" sheet
       Format: Columns 'cusip', 'trade_date' (any row in sheet is considered a reviewed error)
    3. Re-run this script to check for additional errors
"""

using DataFramesMeta, Dates, CSV, Parquet
using SASLib
using XLSX

include("../../src/main.jl")
include("utils_clean_data.jl")
include("../../config/update_config.jl")

# Set up error checking directory
ERROR_CHECK_DIR = "data/error_checks/excel_$(UPDATE_DATE)/"
!isdir(ERROR_CHECK_DIR) && mkpath(ERROR_CHECK_DIR)

# Path to errors file
ERRORS_FILE = "data/error_checks/errors.xlsx"

println("\n" * "="^80)
println("Checking for Extreme Bond Returns in Full Dataset")
println("="^80)
println("Threshold: ±$(EXTREME_RETURN_THRESHOLD*100)%")
println("Excel output: $ERROR_CHECK_DIR")
println("Already-reviewed errors file: $ERRORS_FILE")
println("="^80 * "\n")

# ============================================================================
# STEP 1: LOAD DATA
# ============================================================================

println("[1/6] Loading bond return data...")
bonds = CSV.read("data/output/bonds_full.csv", DataFrame)

println("✓ Loaded bond data")
println("  Date range: $(extrema(bonds.date)[1]) to $(extrema(bonds.date)[2])")
println("  Total observations: $(nrow(bonds))")

# ============================================================================
# STEP 2: LOAD ALREADY-REVIEWED ERRORS
# ============================================================================

println("\n[2/6] Loading already-reviewed errors...")

if isfile(ERRORS_FILE)
    # Read errors.xlsx - expects sheet "TRACE_error" with columns: cusip, trade_date
    try
        # Read TRACE_error sheet
        df_trace = DataFrame(XLSX.readtable(ERRORS_FILE, "TRACE_error"))

        # Check for required columns (cusip and trade_date)
        if !("cusip" in names(df_trace)) || !("trade_date" in names(df_trace))
            error("TRACE_error sheet must contain columns: cusip, trade_date")
        end

        # Select and process - any row in the sheet is considered a reviewed error
        errors_df = select(df_trace, :cusip, :trade_date)
        dropmissing!(errors_df, [:cusip, :trade_date])
        transform!(errors_df, :trade_date => (x -> lastdayofmonth.(x)) => :date)
        unique!(errors_df)

        println("✓ Loaded $(nrow(errors_df)) already-reviewed errors from TRACE_error sheet")
        if nrow(errors_df) > 0
            println("  Date range: $(extrema(errors_df.date)[1]) to $(extrema(errors_df.date)[2])")
            println("  Unique bonds: $(length(unique(errors_df.cusip)))")
        end
    catch e
        @warn "Could not read errors.xlsx TRACE_error sheet: $e"
        @warn "Proceeding without exclusions"
        errors_df = DataFrame(cusip=String[], date=Date[])
    end
else
    println("✓ No errors.xlsx found - checking all extreme returns")
    errors_df = DataFrame(cusip=String[], date=Date[])
end

# ============================================================================
# STEP 3: IDENTIFY EXTREME RETURNS
# ============================================================================

println("\n[3/6] Identifying extreme returns in full dataset...")

# Flag extreme returns using ret_eom only
bonds_extreme = @subset(bonds, abs.(:ret_eom) .>= EXTREME_RETURN_THRESHOLD)
sort!(bonds_extreme, [:cusip, :date])

println("✓ Found $(nrow(bonds_extreme)) extreme return observations in full dataset")
println("  Unique bonds: $(length(unique(bonds_extreme.cusip)))")

# ============================================================================
# STEP 4: EXCLUDE ALREADY-REVIEWED ERRORS
# ============================================================================

println("\n[4/6] Excluding already-reviewed errors...")

n_before = nrow(bonds_extreme)

if nrow(errors_df) > 0
    # Anti-join to exclude already-reviewed errors
    bonds_extreme = antijoin(bonds_extreme, errors_df, on=[:cusip, :date])
end

n_after = nrow(bonds_extreme)
n_excluded = n_before - n_after

println("✓ Excluded $n_excluded already-reviewed errors")
println("  Remaining extreme returns to review: $n_after")
println("  Unique bonds to review: $(length(unique(bonds_extreme.cusip)))")

if nrow(bonds_extreme) == 0
    println("\n" * "="^80)
    println("✓ No new extreme returns to review!")
    println("="^80)
    println("\nAll extreme returns have been reviewed.")
    println("Re-run create_datasets.jl if you have updated the data.")
    println()
    exit(0)
end

# Export extreme returns for review
CSV.write(ERROR_CHECK_DIR*"bond_returns_to_check.csv", bonds_extreme)
println("✓ Saved extreme returns to: $(ERROR_CHECK_DIR)bond_returns_to_check.csv")

# ============================================================================
# STEP 5: LOAD INTRADAY AND DAILY TRACE DATA
# ============================================================================

println("\n[5/6] Loading TRACE data for flagged bonds...")

cusips = unique(bonds_extreme, [:cusip])[!, [:cusip]]

# Load intraday data for flagged CUSIPs only
println("  Loading intraday TRACE data...")
trace_intraday = DataLoader.load_trace_intraday(file="data/wrds/trace_prices.sas7bdat")
trace_intraday = innerjoin(trace_intraday, cusips, on=:cusip)
CSV.write(ERROR_CHECK_DIR*"trace_intraday_to_check.csv", trace_intraday)
println("✓ Loaded intraday data: $(nrow(trace_intraday)) trades")

# Load daily data for flagged CUSIPs only
println("  Loading daily TRACE data...")
trace_daily = DataFrame(read_parquet("data/output/trace_daily.pq")) |> year_month_day_to_date!
trace_daily = innerjoin(trace_daily, cusips, on=:cusip)
CSV.write(ERROR_CHECK_DIR*"trace_daily_to_check.csv", trace_daily)
println("✓ Loaded daily data: $(nrow(trace_daily)) observations")

# ============================================================================
# HELPER FUNCTIONS FOR EXCEL GENERATION
# ============================================================================

"""
    write_error_file(trace_intraday, trace_daily, bonds, cm, cusip; out_path)

Create Excel workbook for a single bond with extreme returns.

Sheets:
- intraday_1cusip: Intraday trades for the problem bond
- intraday_others: Intraday trades for all bonds from same issuer (6-digit CUSIP)
- daily_1cusip: Daily prices for the problem bond
- daily_others: Daily prices for all bonds from same issuer
"""
function write_error_file(trace_intraday, trace_daily, bonds, cm, cusip; write_=true, out_path=ERROR_CHECK_DIR)
    # Match intraday data
    begin
        trace_matched = innerjoin(trace_intraday, cm, on=[:cusip6], makeunique=true)
        @subset!(trace_matched, :date_start .<= :date .<= :date_end)
        trace_matched = trace_matched[.!nonunique(trace_matched[:, [:date, :trd_exctn_tm, :trade_count, :cusip, :price]]), :]
        n_cusips = length(unique(trace_matched.cusip))

        # Unstack by price and volume
        tmp1 = unstack(trace_matched, [:date, :trd_exctn_tm, :trade_count], :cusip, :price)
        tmp2 = unstack(trace_matched, [:date, :trd_exctn_tm, :trade_count], :cusip, :volume)
        select!(tmp1, :date, cusip, :)
        select!(tmp2, :date, cusip, :)

        # Join price and volume
        res_intraday = outerjoin(tmp1, tmp2, on=[:date, :trd_exctn_tm, :trade_count],
                                renamecols="_price" => "_volume")

        res_intraday = leftjoin(res_intraday, cm[:, [:error_date, :marked_obs_ind]], on=[:date =>:error_date])
        sort!(res_intraday, :date)
        select!(res_intraday, :date, :trd_exctn_tm=>identity=>:hour, :marked_obs_ind,
               Not([:trd_exctn_tm, :trade_count]))

        res1_intraday = select(res_intraday, :date, :hour, :marked_obs_ind, cusip*"_price", cusip*"_volume") |>
            x->dropmissing(x, cusip*"_price")
    end

    # Match daily data
    begin
        trace_matched = innerjoin(trace_daily, cm, on=[:cusip6], makeunique=true)
        @subset!(trace_matched, :date_start .<= :date .<= :date_end)
        trace_matched = trace_matched[.!nonunique(trace_matched[:, [:date, :cusip, :price]]), :]

        # Unstack by price and volume
        tmp1 = unstack(trace_matched, [:date], :cusip, :price)
        tmp2 = unstack(trace_matched, [:date], :cusip, :volume)
        select!(tmp1, :date, cusip, :)
        select!(tmp2, :date, cusip, :)

        # Join price and volume
        res_daily = outerjoin(tmp1, tmp2, on=[:date], renamecols="_price" => "_volume")

        res_daily = leftjoin(res_daily, cm[:, [:error_date, :marked_obs_ind]], on=[:date =>:error_date])
        sort!(res_daily, :date)
        select!(res_daily, :date, :marked_obs_ind, :)

        res1_daily = select(res_daily, :date, :marked_obs_ind, cusip*"_price", cusip*"_volume") |>
            x->dropmissing(x, cusip*"_price")
    end

    # Write to Excel
    if write_ == true
        if n_cusips <= 10  # Excel can handle up to 10 bonds per issuer
            XLSX.writetable(out_path*cusip*".xlsx",
                           "intraday_1cusip" => res1_intraday,
                           "intraday_others" => res_intraday,
                           "daily_1cusip" => res1_daily,
                           "daily_others" => res_daily;
                           overwrite=true)
        else  # Too many bonds - split into separate CSV files
            isdir(out_path*cusip) || mkdir(out_path*cusip)
            XLSX.writetable(out_path*cusip*"/"*cusip*".xlsx",
                           "intraday_1cusip" => res1_intraday,
                           "daily_1cusip" => res1_daily;
                           overwrite=true)
            CSV.write(out_path*cusip*"/res_intraday.csv", res_intraday)
            CSV.write(out_path*cusip*"/res_daily.csv", res_daily)
        end
    else
        return res1_intraday, res_intraday, res1_daily, res_daily
    end
end

"""
    write_error_files(trace_intraday, trace_daily, bonds, cusips_months; start_idx, out_path)

Create Excel files for all bonds with extreme returns.
"""
function write_error_files(trace_intraday, trace_daily, bonds, cusips_months; start_idx=1, out_path=ERROR_CHECK_DIR)
    cusips = cusips_months[:, [:cusip]] |> unique

    println("\nGenerating $(nrow(cusips)) Excel files for manual review...")

    for (i, cusip) in enumerate(cusips[start_idx:end, :cusip])
        cm = @subset(cusips_months, :cusip .== cusip)

        if i % 10 == 0
            println("  $(start_idx + i - 1)/$(nrow(cusips)) done - $(Dates.format(now(), "HH:MM"))")
        end

        write_error_file(trace_intraday, trace_daily, bonds, cm, cusip; out_path=out_path)
    end

    println("✓ All Excel files created")
end

# ============================================================================
# STEP 6: PREPARE DATA FOR EXCEL EXPORT
# ============================================================================

println("\n[6/6] Preparing data for Excel export...")

# Create date ranges for each extreme return
cusips_months = bonds_extreme[:, [:cusip, :trade_date]]
@rselect!(cusips_months,
          :cusip,
          :cusip6=:cusip[1:6],
          :date_start=lastdayofmonth.(:trade_date-Month(N_MONTHS_BACK)),
          :date_end=lastdayofmonth.(:trade_date+Month(N_MONTHS_FORWARD)),
          :error_date=:trade_date,
          :marked_obs_ind=true)

# Add trade count for deduplication
transform!(groupby(trace_intraday, [:date, :trd_exctn_tm, :cusip]),
          :price => (x-> 1:1:length(x)) => :trade_count)

println("✓ Prepared $(nrow(cusips_months)) date ranges for export")

# Generate Excel files
println("\nGenerating Excel files for manual review...")

@time write_error_files(trace_intraday, trace_daily, bonds, cusips_months; out_path=ERROR_CHECK_DIR)

# ============================================================================
# SUMMARY
# ============================================================================

println("\n" * "="^80)
println("Error Detection Complete!")
println("="^80)
println("\nSummary:")
println("  Full dataset date range: $(extrema(bonds.date)[1]) to $(extrema(bonds.date)[2])")
println("  Already-reviewed errors excluded: $n_excluded")
println("  New extreme returns found: $(nrow(bonds_extreme))")
println("  Unique bonds affected: $(length(unique(bonds_extreme.cusip)))")
println("  Excel files created: $(length(unique(cusips_months.cusip)))")
println("\nExcel files location:")
println("  $ERROR_CHECK_DIR")

println("\n" * "="^80)
println("Next Steps: Manual Review")
println("="^80)
println("1. Open Excel files in: $ERROR_CHECK_DIR")
println("2. Review each flagged return (marked_obs_ind = TRUE)")
println("3. Check intraday/daily data for pricing errors vs. real trades")
println("4. Add reviewed errors to: $ERRORS_FILE")
println("   Sheet: 'TRACE_error' with columns 'cusip', 'trade_date'")
println("   Any row in the sheet will be excluded from future checks")
println("5. Re-run this script to check for additional errors (reviewed ones will be excluded)")
println()
