# Create datasets used in scientific replication
# Create different versions of daily trace data specific to various internal replication procedures
using DataFramesMeta, Dates, CSV, Parquet
using SASLib
using ShiftedArrays: lag, lead
using RCall

include("../src/main.jl")
include("utils_clean_data.jl")


R""" 
library(BondValuation)
library(R.utils)
"""


# Load packages for parallel processing
using Distributed
n_splits = 8
addprocs(n_splits, exeflags="--project")
@everywhere using DataFramesMeta
@everywhere using RCall
@everywhere R""" 
library(BondValuation)
library(R.utils)
"""
@everywhere include("../src/main.jl")



#### DATA CREATION BEGINS HERE  ####

@time trace_intraday = DataLoader.load_trace_intraday(;file=file="data/trace/trace_prices.sas7bdat")


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

###############################################



### CREATE RISK MEASURES ###
include("../src/main.jl")

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
partitions = [gdf[1 + Int(ceil(i*length(gdf)/n_splits)) : Int(ceil((i+1)*length(gdf)/n_splits)) ] for i in 0:n_splits-1]
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
include("../src/main.jl")

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

#bonds = CSV.read("data/output/warga_ice_trace.csv", DataFrame)
include("../src/main.jl")
bonds = CSV.read("data/output/bonds.csv", DataFrame)

gdf = groupby(bonds, :cusip, sort=true)
partitions = [gdf[1 + Int(ceil(i*length(gdf)/n_splits)) : Int(ceil((i+1)*length(gdf)/n_splits)) ] for i in 0:n_splits-1]
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
println("\nNext step: Run create_factor_data.jl to create factor regressors and returns")
println("  julia --project=. scripts/create_factor_data.jl")
println() 