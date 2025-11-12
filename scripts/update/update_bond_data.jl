"""
    update_bond_data.jl

Process incremental TRACE data and create bond return datasets.

This script processes NEW bond trading data for a specific time period and creates
all necessary intermediate files (daily prices, risk measures, returns, factors, etc.).

Usage:
    julia --project=. scripts/update/update_bond_data.jl

Configuration:
    Edit config/update_config.jl to set TIMEPERIOD and UPDATE_DATE

Output files (in data/output/update_YYYY_MM_DD/):
    - trace_daily_PERIOD.pq
    - illiq_PERIOD.csv
    - trace_monthly.csv
    - risk_measures_trace.csv
    - date_vectors_trace.csv
    - dates_trace.csv
    - gsw.csv
    - bonds.csv
    - treasury_risk_measures_trace.csv
    - bonds_full.csv (complete with factors and value signals)
    - firms.csv (firm-level aggregated returns)
    - factor_regressors.csv
    - factor_regressors_bbw.csv

Next step: Run check_for_errors.jl to identify and review extreme returns
"""

using DataFramesMeta, Dates, CSV, Parquet
using SASLib
using ShiftedArrays: lag, lead
using RCall
using Distributed

include("../../src/main.jl")
include("../utils/utils_clean_data.jl")
include("../../config/update_config.jl")

println("\n" * "="^80)
println("Processing Incremental Bond Data Update")
println("="^80)
println("Time period: $TIMEPERIOD")
println("Output path: $PATH")
println("Workers: $N_WORKERS")
println("="^80 * "\n")

# ============================================================================
# STEP 1: LOAD AND PROCESS TRACE INTRADAY DATA
# ============================================================================

println("[1/10] Loading TRACE intraday data...")
@time trace_intraday = DataLoader.load_trace_intraday(file="data/wrds/trace_prices"*TIMEPERIOD*".sas7bdat")
println("✓ Loaded $(nrow(trace_intraday)) intraday trades")

# ============================================================================
# STEP 2: COMPUTE REVERSAL FLAGS (OUTLIER DETECTION)
# ============================================================================

println("\n[2/10] Computing reversal flags for outlier detection...")
trace_intraday.keep .= true
@time transform!(groupby(trace_intraday, :cusip), compute_reversal_flags!)
select!(trace_intraday, Not(:x1))
@subset!(trace_intraday, :keep .== true)
println("✓ Reversal flags computed")

# ============================================================================
# STEP 3: AGGREGATE TO DAILY PRICES
# ============================================================================

println("\n[3/10] Aggregating to daily prices...")
trace_daily = @chain trace_intraday begin
    transform(:price => ByRow(x-> x == 100.0)=>:trade100)
    @combine(groupby(_, [:cusip, :date]),
             :price = sum(:volume .* :price) / sum(:volume),  # Value-weighted
             :volume = sum(:volume),
             :trade100=any(:trade100))
    @rtransform!(:cusip6=:cusip[1:6])

    sort([:cusip, :date])
    transform(:date=>(x->lastdayofmonth.(x))=>:eom)
    @transform!(groupby(_, [:cusip, :eom]), :price_lag = lag(:price, 1))
    @transform(:ret = :price ./ :price_lag .- 1.)
    select!(Not(:eom))
    date_to_year_month_day!(_)
end

write_parquet(PATH*"trace_daily"*TIMEPERIOD*".pq", trace_daily)
println("✓ Daily prices saved: $(PATH)trace_daily$(TIMEPERIOD).pq")

# ============================================================================
# STEP 4: COMPUTE ILLIQUIDITY MEASURES
# ============================================================================

println("\n[4/10] Computing illiquidity measures...")
trace_daily = DataFrame(read_parquet(PATH*"trace_daily"*TIMEPERIOD*".pq")) |> year_month_day_to_date!
illiq = compute_illiq(trace_daily)
CSV.write(PATH*"illiq"*TIMEPERIOD*".csv", illiq)
println("✓ Illiquidity measures saved: $(PATH)illiq$(TIMEPERIOD).csv")

# ============================================================================
# STEP 5: AGGREGATE TO MONTHLY PRICES
# ============================================================================

println("\n[5/10] Aggregating to monthly prices...")
trace_month = Preprocess.agg_daily_trace_to_month(trace_daily)
CSV.write(PATH*"trace_monthly.csv", trace_month)
println("✓ Monthly prices saved: $(PATH)trace_monthly.csv")

# ============================================================================
# STEP 6: COMPUTE BOND RISK MEASURES (PARALLEL)
# ============================================================================

println("\n[6/10] Computing bond risk measures (yields, duration, convexity)...")
println("Starting $N_WORKERS parallel workers...")

addprocs(N_WORKERS, exeflags="--project")
@everywhere using DataFramesMeta
@everywhere using RCall
@everywhere R"""
library(BondValuation)
library(R.utils)
"""
@everywhere include("../src/main.jl")

# Prepare data
trace_month = CSV.read(PATH*"trace_monthly.csv", DataFrame)
fisd = Preprocess.Fisd()
df = innerjoin(trace_month, fisd.mergent, on=:cusip)
df = Preprocess.add_ratings(df, fisd.ratings)
dropmissing!(df, [:cusip, :trade_date, :first_interest_date, :last_trade_date, :settlement_date])

@subset!(df, :date .< :maturity)
@rsubset!(df, :coupon_type in ["F", "Z"])
Preprocess.filter_bonds!(df; print_obs=true)

# Compute bond values in parallel
gdf = groupby(df, :cusip, sort=true)
partitions = [gdf[1 + Int(ceil(i*length(gdf)/N_WORKERS)) : Int(ceil((i+1)*length(gdf)/N_WORKERS)) ] for i in 0:N_WORKERS-1]

println("Processing $(length(gdf)) bonds across $N_WORKERS workers...")
@time res = pmap(x->Preprocess.bond_values(x, treasury=false), partitions)

yields = vcat([res[i][1] for i in 1:length(res)]...)
error_cusips = vcat([res[i][2] for i in 1:length(res)]...)

CSV.write(PATH*"risk_measures_trace.csv", yields)
CSV.write(PATH*"error_cusips.csv", error_cusips)
println("✓ Risk measures saved: $(PATH)risk_measures_trace.csv")
println("  Errors logged: $(nrow(error_cusips)) CUSIPs")

# ============================================================================
# STEP 7: EXTRACT COUPON PAYMENT SCHEDULES
# ============================================================================

println("\n[7/10] Extracting coupon payment schedules...")
coups, dates, error_cusips = Preprocess.bond_dates(gdf)
CSV.write(PATH*"date_vectors_trace.csv", dates)
CSV.write(PATH*"dates_trace.csv", coups)
println("✓ Coupon schedules saved")

# ============================================================================
# STEP 8: CREATE BOND RETURN DATASET
# ============================================================================

println("\n[8/10] Creating main bond return dataset...")
include("../src/main.jl")

trace_month = CSV.read(PATH*"trace_monthly.csv", DataFrame)
rf = DataLoader.load_rf()
fisd = Preprocess.Fisd()

# Download fresh GSW data
gsw = Preprocess.get_gsw_params()
CSV.write(PATH*"gsw.csv", gsw)
println("✓ GSW treasury curve data downloaded")

# Compute bond returns
bonds = Preprocess.compute_bond_returns(
    trace_month, fisd, rf;
    min_tmt=1.0,
    yield_file=PATH*"risk_measures_trace.csv",
    keep_def_rets=false,
    remove_errors=true,
    add_filters=true
)

transform!(bonds, :rating_num=>ByRow(x->ceil(x)), renamecols=false)
sort!(bonds, [:cusip, :date])

# Add bond characteristics
bonds.bond_age_pct = Factors.age_percent(bonds)
bonds.bm = Factors.book_to_market(bonds)

# Add temporal features (time to next coupon, remaining coupons)
bonds = add_temporal_features(bonds; trace=true, file=PATH*"date_vectors_trace.csv")

# Add treasury-equivalent prices
leftjoin!(bonds, gsw, on=:date)
transform!(bonds, AsTable(:) => ByRow(x-> Preprocess.price_coupon_treasury(
    x.coupon, x.remcoup, x.interest_frequency, x.tmt, x.time_next_coup,
    x.beta0, x.beta1, x.beta2, x.beta3, x.tau1, x.tau2
)) => :price_ctreasury)
select!(bonds, Not(Cols(startswith("beta"))))
select!(bonds, Not(Cols(startswith("tau"))))

sort!(bonds, [:cusip, :date])
CSV.write(PATH*"bonds.csv", bonds)
println("✓ Bond returns saved: $(PATH)bonds.csv")

# ============================================================================
# STEP 9: COMPUTE TREASURY RISK MEASURES (PARALLEL)
# ============================================================================

println("\n[9/10] Computing treasury-equivalent risk measures...")
gdf = groupby(bonds, :cusip, sort=true)
partitions = [gdf[1 + Int(ceil(i*length(gdf)/N_WORKERS)) : Int(ceil((i+1)*length(gdf)/N_WORKERS)) ] for i in 0:N_WORKERS-1]

@time res1 = pmap(x->Preprocess.bond_values(x, treasury=true), partitions)
rf_yields = vcat([res1[i][1] for i in 1:length(res1)]...)

CSV.write(PATH*"treasury_risk_measures_trace.csv", rf_yields)
println("✓ Treasury risk measures saved")

# ============================================================================
# STEP 10: ADD TREASURY RETURNS TO FINAL DATASET
# ============================================================================

println("\n[10/13] Adding treasury returns to final dataset...")
rf_yields = CSV.read(PATH*"treasury_risk_measures_trace.csv", DataFrame)
bonds = leftjoin(bonds, rf_yields[:, Not(:coupacc1)], on=[:cusip, :date])
transform!(bonds, [:yield, :yield_rf] => ByRow((y, y_rf)-> y-y_rf) => :yield_spread)
bonds = Preprocess.add_treasury_returns(bonds)
CSV.write(PATH*"bonds_full.csv", bonds)
println("✓ Final dataset saved: $(PATH)bonds_full.csv")

################################################################################
# ADD VALUE, EQUITY MOMENTUM AND AGGREGATE TO FIRM RETURNS
##############################################################################

bonds = CSV.read(PATH*"bonds_full.csv", DataFrame)

# ============================================================================
# STEP 11: CREATE FACTOR REGRESSORS
# ============================================================================

println("\n[11/13] Creating factor regressors (market, size, value, etc.)...")
factor_regressors = Pfs.FactorRegressor(bonds).factor_regressors
factor_regressors = replace_nans(factor_regressors) |> x->dropmissing(x, :market)
CSV.write(PATH*"factor_regressors.csv", factor_regressors)
println("✓ Factor regressors saved to $(PATH)factor_regressors.csv")

# ============================================================================
# STEP 12: ADD BBW-FACTORS (VaR and Liquidity Betas)
# ============================================================================

println("\n[12/13] Computing BBW-style factors (VaR, liquidity betas)...")
rolling_signal_functions = Dict(
    :VaR => Factors.VaR,
    :amh_liq_ret => Factors.liquidity_betas
)
rolling_signals = Pfs.compute_rolling_signals(bonds, factor_regressors, rolling_signal_functions; window=36, min_window=24)

df = bonds[:, [:cusip, :date, :ret_exc_lead, :ret_texc_lead, :MV, :rating_num]]
df = leftjoin(df, rolling_signals, on=[:date, :cusip])
subset!(df, :rating_num=> ByRow(x-> ismissing(x) || x .<=22.))  # Remove non-missing values with rating above 22 (D)
transform!(df, :rating_num=>ByRow(x->rating_conversion[round(x)])=>:rating)

signal_names = [:VaR, :amh_liq_ret]
pfs, factor_returns, factor_returns_double = Pfs.compute_characteristic_pfs(df, signal_names; double_sort=:rating, is_cut=false, N_sorts=3)
pfs, factor_returns1 = Pfs.compute_characteristic_pfs(df, :rating_num; double_sort=nothing, is_cut=false, N_sorts=3)
leftjoin!(factor_returns, factor_returns1, on=:date)
leftjoin!(factor_regressors, factor_returns, on=:date) |> x->sort(x, :date)

rename!(factor_regressors, :VaR=>:VaR_ret, :rating_num=>:rating_ret)
CSV.write(PATH*"factor_regressors_bbw.csv", factor_regressors)
println("✓ BBW factor regressors saved to $(PATH)factor_regressors_bbw.csv")

# Merge illiquidity onto bonds
illiq = CSV.read(PATH*"illiq"*TIMEPERIOD*".csv", DataFrame)
leftjoin!(bonds, illiq, on=[:cusip, :date=>:eom])

# Merge equity return onto bonds - used for equity momentum
stocks = CSV.read("data/wrds/stocks.csv", DataFrame) |> dropmissing
rename!(stocks, :id=>:permno, :eom=>:date)
@transform!(stocks, :date=Date.(string.(:date), "yyyymmdd"))
leftjoin!(bonds, stocks, on=[:date, :permno], matchmissing=:equal)

# ============================================================================
# STEP 13: ADD VALUE SIGNALS AND COMPUTE FIRM RETURNS
# ============================================================================

println("\n[13/13] Adding value signals and computing firm-level returns...")

# Add Value signals
transform!(groupby(bonds, :cusip), :duration => lead)
tmp_ret_vol = Pfs.compute_rolling_signals(bonds, factor_regressors, Dict(:ret_vol=>x->Factors.vol(x, col=:ret_exc)); level=:cusip, window=12, min_window=6)
leftjoin!(bonds, tmp_ret_vol, on=[:date, :cusip])

transform!(bonds, :yield_spread => ByRow(x-> ismissing(x) || x<0. ? missing : x), renamecols=false)  # Set negative yield spreads to missing
transform!(bonds, [:yield_spread, :duration, :rating_num, :ret_vol] .=> ByRow(x->log(x)) .=> (x->x*"_log"))
bonds.value = missings(Float64, nrow(bonds))
gdf = groupby(bonds, :date)
transform(gdf) do sdf
    Factors.value(sdf, y=:yield_spread_log)
    return sdf
end

numcols = [:price_eom, :ret_eom, :ret_exc, :ret_exc_lead, :ret_texc_lead, :ret_eq, :value, :illiq, :rating_num, :MV, :amount_outstanding, :MV_lag, :MV_lead, :duration, :tmt, :convexity, :bond_age_pct, :bm, :yield_spread, :yield]
firms = Preprocess.compute_firm_ret(bonds, numcols; firm_id=:permno, duration_adjust=true)

# Save final datasets
CSV.write(PATH*"bonds_full.csv", bonds)
CSV.write(PATH*"firms.csv", firms)
println("✓ Final datasets saved:")
println("  - $(PATH)bonds_full.csv")
println("  - $(PATH)firms.csv")

# ============================================================================
# SUMMARY
# ============================================================================

println("\n" * "="^80)
println("Incremental Data Processing Complete!")
println("="^80)
println("\nOutput files created in: $PATH")
println("  - trace_daily$(TIMEPERIOD).pq")
println("  - illiq$(TIMEPERIOD).csv")
println("  - trace_monthly.csv")
println("  - risk_measures_trace.csv")
println("  - date_vectors_trace.csv")
println("  - dates_trace.csv")
println("  - gsw.csv")
println("  - bonds.csv")
println("  - treasury_risk_measures_trace.csv")
println("  - bonds_full.csv (complete with factors and value signals)")
println("  - firms.csv (firm-level aggregated returns)")
println("  - factor_regressors.csv")
println("  - factor_regressors_bbw.csv")

println("\n" * "="^80)
println("Next Step: Error Detection")
println("="^80)
println("Run the following command to check for extreme returns:")
println("  julia --project=. scripts/update/check_for_errors.jl")
println()
