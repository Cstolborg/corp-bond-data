"""
Usage:
    julia --project=. scripts/main/create_datasets.jl

"""

using DataFramesMeta, Dates, CSV, Parquet
using SASLib
using ShiftedArrays: lag, lead
using RCall
using Distributed


include("../../src/main.jl")
include("utils_clean_data.jl")
include("../../config/update_config.jl")

R"""
library(BondValuation)
library(R.utils)
"""

println("\n" * "="^80)
println("Creating Bond Data")
println("="^80)
println("CPU cores detected: $(Sys.CPU_THREADS)")
println("Workers: $N_WORKERS")
println("="^80 * "\n")


# Load packages for parallel processing
addprocs(N_WORKERS, exeflags="--project")
@everywhere using DataFramesMeta
@everywhere using RCall
@everywhere R"""
library(BondValuation)
library(R.utils)
"""
@everywhere include("../../src/main.jl")

#### DATA CREATION BEGINS HERE  ####


@time trace_intraday = DataLoader.load_trace_intraday(file="data/wrds/trace_prices.sas7bdat")


# Compute reversal flags
trace_intraday.keep .= true
@time transform!(groupby(trace_intraday, :cusip), compute_reversal_flags!)
select!(trace_intraday, Not(:x1))

trace_daily = @chain trace_intraday begin
    @subset(:keep.==true)
    transform(:price => ByRow(x-> x == 100.0)=>:trade100)
    @combine(groupby(_, [:cusip, :date]), :price = sum(:volume .* :price) / sum(:volume), :volume = sum(:volume), :trade100=any(:trade100))  # Value-weighted intraday price
    @rtransform!(:cusip6=:cusip[1:6])
    
    sort([:cusip, :date])
    transform(:date=>(x->lastdayofmonth.(x))=>:eom)
    @transform!(groupby(_, [:cusip, :eom]), :price_lag = lag(:price, 1))
    @transform(:ret = :price ./ :price_lag .- 1.)  # Used to compute liquidity factors
    select!(Not(:eom))
    date_to_year_month_day!(_)
end
write_parquet("data/output/trace_daily.pq", trace_daily)

trace_daily = DataFrame(read_parquet("data/output/trace_daily.pq")) |> year_month_day_to_date!

illiq = compute_illiq(trace_daily)
CSV.write("data/output/illiq.csv", illiq)

trace_month = Preprocess.agg_daily_trace_to_month(trace_daily)
CSV.write("data/output/trace_monthly.csv", trace_month)

trace_intraday = nothing  # Free memory

###############################################

### CREATE RISK MEASURES ###
fisd = Preprocess.Fisd()

begin  # Get data
trace_month = CSV.read("data/output/trace_monthly.csv", DataFrame)

df = innerjoin(trace_month, fisd.mergent, on=:cusip)
df = Preprocess.add_ratings(df, fisd.ratings)
dropmissing!(df, [:cusip, :trade_date, :first_interest_date, :last_trade_date, :settlement_date])

@subset!(df, :date .< :maturity)
@rsubset!(df, :coupon_type in ["F", "Z"])
Preprocess.filter_bonds!(df; print_obs=true)
end

gdf = groupby(df, :cusip, sort=true)
#@time tmp, _ = Preprocess.bond_values(gdf[1:50], treasury=false)
partitions = [gdf[1 + Int(ceil(i*length(gdf)/N_WORKERS)) : Int(ceil((i+1)*length(gdf)/N_WORKERS)) ] for i in 0:N_WORKERS-1]
@time res = pmap(x->Preprocess.bond_values(x, treasury=false), partitions)
yields = vcat([res[i][1] for i in 1:length(res)]...)
error_cusips = vcat([res[i][2] for i in 1:length(res)]...)

CSV.write("data/output/risk_measures_trace.csv", yields)
CSV.write("data/output/error_cusips.csv", error_cusips)

coups, dates, error_cusips = Preprocess.bond_dates(gdf)
CSV.write("data/output/date_vectors_trace.csv", dates)
CSV.write("data/output/dates_trace.csv", coups)

###########################################

### CREATE MAIN BOND RETURN DATASET ###
trace_month = CSV.read("data/output/trace_monthly.csv", DataFrame)
rf = DataLoader.load_rf()
fisd = Preprocess.Fisd()

# Load GSW treasury yield curve parameters (downloaded by check_data_files.jl)
gsw = CSV.read("data/output/gsw.csv", DataFrame)


begin
bonds = Preprocess.compute_bond_returns(
        trace_month, fisd, rf; min_tmt=1.0,
        yield_file="data/output/risk_measures_trace.csv",
        keep_def_rets=false, remove_errors=true, add_filters=true)
transform!(bonds, :rating_num=>ByRow(x->ceil(x)), renamecols=false)
sort!(bonds, [:cusip, :date])
bonds.bond_age_pct = Factors.age_percent(bonds)
bonds.bm = Factors.book_to_market(bonds)  # Face value divided by price

# Add temporal features, remcoups, time_next_coup etc.
bonds = add_temporal_features(bonds; trace=true)
leftjoin!(bonds, gsw, on=:date)
transform!(bonds, AsTable(:) => ByRow(x-> Preprocess.price_coupon_treasury(x.coupon, x.remcoup, x.interest_frequency, x.tmt, x.time_next_coup, x.beta0, x.beta1, x.beta2, x.beta3, x.tau1, x.tau2)) => :price_ctreasury )
select!(bonds, Not(Cols(startswith("beta"))))
select!(bonds, Not(Cols(startswith("tau"))))
 
sort!(bonds, [:cusip, :date])
end
CSV.write("data/output/bonds.csv", bonds)

########################################################################

##### COMPUTE TREASURY RISK MEASURES  ###################

bonds = CSV.read("data/output/bonds.csv", DataFrame)

gdf = groupby(bonds, :cusip, sort=true)
partitions = [gdf[1 + Int(ceil(i*length(gdf)/N_WORKERS)) : Int(ceil((i+1)*length(gdf)/N_WORKERS)) ] for i in 0:N_WORKERS-1]
#@time res1, _ = Preprocess.bond_values(gdf[1:50], treasury=true)
@time res1 = pmap(x->Preprocess.bond_values(x, treasury=true), partitions)

rf_yields = vcat([res1[i][1] for i in 1:length(res1)]...)
rf_errors = vcat([res1[i][2] for i in 1:length(res1)]...)

CSV.write("data/output/treasury_risk_measures_trace.csv", rf_yields)
CSV.write("data/output/treasury_risk_measures_trace_errors.csv", rf_errors)

# Add to main data
rf_yields = CSV.read("data/output/treasury_risk_measures_trace.csv", DataFrame)
bonds = leftjoin(bonds, rf_yields[:, Not(:coupacc1)], on=[:cusip, :date])
transform!(bonds, [:yield, :yield_rf] => ByRow((y, y_rf)-> y-y_rf) => :yield_spread)
bonds = Preprocess.add_treasury_returns(bonds)
CSV.write("data/output/bonds_full.csv", bonds)




################################################################################
# ADD VALUE, EQUITY MOMENTUN AND AGGREGATE TO FIRM RETURNS
##############################################################################

bonds = CSV.read("data/output/bonds_full.csv", DataFrame)

# Factor regressor

factor_regressors = Pfs.FactorRegressor(bonds, trace_daily).factor_regressors
factor_regressors = replace_nans(factor_regressors) |> x->dropmissing(x, :market)
CSV.write("data/output/factor_regressors.csv", factor_regressors)
println("✓ Factor regressors saved to data/output/factor_regressors.csv")

# ============================================================================
# Add BBW-Factors (VaR and Liquidity Betas)
# ============================================================================

println("\n[3/5] Computing BBW-style factors (VaR, liquidity betas)...")
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
CSV.write("data/output/factor_regressors_bbw.csv", factor_regressors)
println("✓ BBW factor regressors saved to data/output/factor_regressors_bbw.csv")


# Merge illiquidity onto bonds

illiq = CSV.read("data/output/illiq.csv", DataFrame)
leftjoin!(bonds, illiq, on=[:cusip, :date=>:eom])

# Merge equity return onto bonds - used for equity mometum
stocks = CSV.read("data/wrds/stocks.csv", DataFrame) |> dropmissing
rename!(stocks, :id=>:permno, :eom=>:date)
@transform!(stocks, :date=Date.(string.(:date), "yyyymmdd"))
leftjoin!(bonds, stocks, on=[:date, :permno], matchmissing=:equal)


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


numcols = [:price_eom, :ret_eom, :ret_exc, :ret_exc_lead, :ret_texc, :ret_eq, :value, :illiq, :rating_num, :MV, :amount_outstanding, :MV_lag, :MV_lead, :duration, :tmt, :convexity, :bond_age_pct, :bm, :yield_spread, :yield]
firms = Preprocess.compute_firm_ret(bonds, numcols; firm_id=:permno, duration_adjust=true)

transform!(bonds, :rating_num=>ByRow(x->rating_conversion[round(x)])=>:rating)
transform!(firms, :rating_num=>ByRow(x->rating_conversion[round(x)])=>:rating)





# Save final datasets
CSV.write("data/output/bonds_full.csv", bonds)
CSV.write("data/output/firms.csv", firms)

bonds_subset = select(bonds, :cusip, :permno, :date, :name, :MV, :price_eom, :ret_eom, :ret_exc, :ret_texc, :duration, :yield, :tmt, :rating=>:rating_group, :rating_num, :ret_eq, :value, :bond_age_pct, :yield_spread, :amount_outstanding)
firms_subset = select(firms, :permno, :date, :MV, :price_eom, :ret_eom, :ret_exc, :ret_texc, :duration, :yield, :tmt, :rating=>:rating_group, :rating_num, :ret_eq, :value, :bond_age_pct, :yield_spread, :amount_outstanding)
# Get unique name per (permno, date) to avoid creating duplicate rows in join
name_lookup = combine(first, groupby(dropmissing(bonds_subset, :permno), [:permno, :date]))[:, [:permno, :date, :name]]
firms_subset = leftjoin(firms_subset, name_lookup, on=[:permno, :date])
select!(firms_subset, :permno, :date, :name, :MV, :)

# Subset to dates <= LAST_DATE
@subset!(bonds_subset, :date .<= LAST_DATE)
@subset!(firms_subset, :date .<= LAST_DATE)

CSV.write("data/data_to_share/bonds.csv", bonds_subset)
CSV.write("data/data_to_share/firms.csv", firms_subset)

######################################################################################################

println("\n" * "="^80)
println("Main Dataset Creation Complete!")
println("="^80)
println("\nOutput files created:")
println("  - data/output/trace_daily.pq")
println("  - data/output/trace_monthly.csv")
println("  - data/output/illiq.csv")
println("  - data/output/risk_measures_trace.csv")
println("  - data/output/date_vectors_trace.csv")
println("  - data/output/dates_trace.csv")
println("  - data/output/bonds.csv")
println("  - data/output/treasury_risk_measures_trace.csv")
println("  - data/output/bonds_full.csv")
println("\n✓ Pipeline complete!")
println()