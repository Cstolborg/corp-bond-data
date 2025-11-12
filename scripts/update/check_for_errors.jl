"""
    check_for_errors.jl

Detect extreme bond returns and create Excel files for manual review.

This script identifies bonds with extreme returns (absolute value >= 32.6%) and
creates detailed Excel workbooks showing intraday and daily pricing data for
manual error classification.

Usage:
    julia --project=. scripts/check_for_errors.jl

Configuration:
    Edit UPDATE_DATE below to match the update directory you want to check

Input files (from update_bond_data.jl):
    - data/output/update_YYYY_MM_DD/bonds.csv
    - data/output/update_YYYY_MM_DD/trace_daily_PERIOD.pq
    - data/wrds/trace_prices_PERIOD.sas7bdat (intraday data)

Output:
    - Excel files in data/output/update_YYYY_MM_DD/excel_files/
    - One .xlsx file per bond with extreme returns
    - Each file contains 4 sheets: intraday/daily data for the bond and its issuer

Next step:
    1. Manually review Excel files and mark errors
    2. Run merge_datasets.jl to combine clean data
"""

using DataFramesMeta, Dates, CSV, Parquet
using SASLib
using XLSX

include("../../src/main.jl")
include("../utils/utils_clean_data.jl")
include("../../config/update_config.jl")

println("\n" * "="^80)
println("Checking for Extreme Bond Returns")
println("="^80)
println("Update path: $PATH")
println("Threshold: ±$(EXTREME_RETURN_THRESHOLD*100)%")
println("Excel output: $EXCEL_PATH")
println("="^80 * "\n")

# ============================================================================
# STEP 1: LOAD DATA
# ============================================================================

println("[1/5] Loading bond return data...")
bonds = CSV.read(PATH*"bonds_full.csv", DataFrame)

# Get date range for filtering
date_range = extrema(bonds.date)
println("✓ Loaded bond data: $(date_range[1]) to $(date_range[2])")

# ============================================================================
# STEP 2: IDENTIFY EXTREME RETURNS
# ============================================================================

println("\n[2/5] Identifying extreme returns...")

# Compute simple returns for comparison
@transform!(groupby(bonds, :cusip), :ret_simple=:price_eom ./ :price_eom_lag .- 1.)

# Flag extreme returns (both ret_eom and ret_simple)
bonds_extreme = @subset(bonds,
    :date .>= date_range[1],
    (abs.(:ret_eom) .>= EXTREME_RETURN_THRESHOLD))

bonds_extreme_simple = @subset(bonds,
    :date .>= date_range[1],
    (abs.(:ret_simple) .>= EXTREME_RETURN_THRESHOLD))

bonds_extreme = vcat(bonds_extreme, bonds_extreme_simple) |>
    x->unique(x, [:cusip, :date]) |>
    x->sort(x, [:cusip, :date])

println("✓ Found $(nrow(bonds_extreme)) extreme return observations")
println("  Unique bonds: $(length(unique(bonds_extreme.cusip)))")

# Export extreme returns for review
CSV.write(PATH*"bond_returns_to_check.csv", bonds_extreme)
println("✓ Saved extreme returns to: $(PATH)bond_returns_to_check.csv")

# ============================================================================
# STEP 3: LOAD INTRADAY AND DAILY TRACE DATA
# ============================================================================

println("\n[3/5] Loading TRACE data for flagged bonds...")

cusips = unique(bonds_extreme, [:cusip])[!, [:cusip]]

# Load intraday data
trace_intraday = DataLoader.load_trace_intraday(file="data/wrds/trace_prices"*TIMEPERIOD*".sas7bdat")
trace_intraday = innerjoin(trace_intraday, cusips, on=:cusip)
CSV.write(PATH*"trace_intraday_to_check.csv", trace_intraday)
println("✓ Loaded intraday data: $(nrow(trace_intraday)) trades")

# Load daily data
trace_daily = DataFrame(read_parquet(PATH*"trace_daily"*TIMEPERIOD*".pq")) |> year_month_day_to_date!
trace_daily = innerjoin(trace_daily, cusips, on=:cusip)
CSV.write(PATH*"trace_daily_to_check.csv", trace_daily)
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
function write_error_file(trace_intraday, trace_daily, bonds, cm, cusip; write_=true, out_path=EXCEL_PATH)
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
function write_error_files(trace_intraday, trace_daily, bonds, cusips_months; start_idx=1, out_path=EXCEL_PATH)
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
# STEP 4: PREPARE DATA FOR EXCEL EXPORT
# ============================================================================

println("\n[4/5] Preparing data for Excel export...")

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

# ============================================================================
# STEP 5: GENERATE EXCEL FILES
# ============================================================================

println("\n[5/5] Generating Excel files for manual review...")

@time write_error_files(trace_intraday, trace_daily, bonds, cusips_months; out_path=EXCEL_PATH)

# ============================================================================
# SUMMARY
# ============================================================================

println("\n" * "="^80)
println("Error Detection Complete!")
println("="^80)
println("\nSummary:")
println("  Extreme returns found: $(nrow(bonds_extreme))")
println("  Unique bonds affected: $(length(unique(bonds_extreme.cusip)))")
println("  Excel files created: $(length(unique(cusips_months.cusip)))")
println("\nExcel files location:")
println("  $EXCEL_PATH")

println("\n" * "="^80)
println("Next Steps: Manual Review")
println("="^80)
println("1. Open Excel files in: $EXCEL_PATH")
println("2. Review each flagged return (marked_obs_ind = TRUE)")
println("3. Check intraday/daily data for pricing errors vs. real trades")
println("4. Mark errors in a separate tracking spreadsheet")
println("5. Run merge_datasets.jl to combine clean data")
println()
