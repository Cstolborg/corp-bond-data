"""
Concerns about Warga dataset:
- No documentation
- More than 130k obs has rating above 22 (e.g. 31) or missing
- A return of zero is assumed to be a missing return
- 1984-12-31 is missing
"""

# This file performs out-of-sample test for bond factors on old data
using DataFramesMeta, Dates, CSV, Parquet
using SASLib
using ShiftedArrays: lead, lag
using RCall
include("../src/main.jl")

function get_dates(;trace=true)
    if trace==true
        dates = CSV.read("scripts/scientific_replication/data/date_vectors_trace.csv", DataFrame) |>x->dropmissing(x,:RealDates) |>x->@transform(x, :cusip, :eom=lastdayofmonth.(:RealDates))
    else
        dates = CSV.read("scripts/scientific_replication/data/date_vectors_warga_ice.csv", DataFrame) |>x->dropmissing(x,:RealDates) |>x->@transform(x, :cusip, :eom=lastdayofmonth.(:RealDates))
    end
    @transform!(groupby(dates, :cusip), :eom_lead=lead(:eom))
    datesv = @rsubset(dates, :eom==:eom_lead; view=true)
    datesv = @rsubset(datesv, :RD_indexes<2.0; view=true)
    @rtransform!(datesv, :eom=lastdayofmonth(:eom-Month(1)))
    select!(dates, :cusip, :eom, :CoupDates)
    return dates
end

function get_temporal_features(dates; n_expand=12)
    df = unique(dates, [:cusip, :eom])
    #df = @subset(df, :cusip.=="000336AE7")
    sort!(df, [:cusip, :eom])
    @transform!(groupby(df, :cusip), :remcoup=length(:cusip)-1:-1:0, :next_coup=lag(:CoupDates))

    df = calendar_fill(df, date_col=:eom, n_expand=n_expand)
    @transform!(groupby(df, :cusip), :remcoup=ffill(:remcoup), :next_coup=ffill(:CoupDates))#, :last_coup=ffill(:next_coup))
    @transform!(groupby(df, :cusip), :remcoup=bfill(:remcoup), :next_coup=bfill(:next_coup))#, :last_coup=ffill(:next_coup))
    @transform!(groupby(df, :cusip), :next_coup_lead=lead(:next_coup))#, :last_coup=ffill(:next_coup))
    dropmissing!(df, :next_coup)
    return df
end

function add_temporal_features(df; trace=true)
    dates = get_dates(trace=trace)
    dates1 = get_temporal_features(dates, n_expand=12)

    df = leftjoin(df, dates1, on=[:cusip, :date=>:eom]) |> x->sort(x, [:cusip, :date])
    @transform!(groupby(df, :cusip), :remcoup=bfill(:remcoup), :next_coup=bfill(:next_coup))

    # Handle cases where settlement date is after coupon payment
    # Match on year and month and if settlement date is then above coupon payment, lead remcoup and next_coup 1
    #dfv = @rsubset(df, !ismissing(:next_coup); view=true)
    
    dfv = @rsubset(df, (year(:settlement_date)==year(:next_coup)) && (month(:settlement_date)==month(:next_coup) && (day(:settlement_date)>day(:next_coup))); view=true)
    @rtransform!(dfv, :remcoup=:remcoup-1, :next_coup=:next_coup_lead)

    # Set next coup to missing in peiods where settlement_date > maturity
    #dfv = @rsubset(df, :settlement_date > :maturity; view=true)
    @rtransform!(df, :time_next_coup = Dates.value(:next_coup - :date)/360)#[!, [:cusip, :date, :next_coup, :tmt, :maturity, :time_next_coup]] |> x->sort(x, :time_next_coup)
    return df
end


# Load market and portfolio data
ff = DataLoader.load_ff()
rf = DataLoader.load_rf()
fisd = Preprocess.Fisd()

# Bond data
links = Preprocess.load_cusip_permno_gvkey()
ice = Preprocess.process_ice()
warga = Preprocess.process_warga()
out = Preprocess.combine_warga_ice(warga, ice, fisd, links, rf; calendar_lag=true, min_tmt=1., add_filters=true)
out.bond_age_pct = Factors.age_percent(out)
out.bm = Factors.book_to_market(out)  # Face value divided by price

############################################################################

### CREATE RISK MEASURES   ###
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

df = copy(out)
gdf = groupby(df, :cusip; sort=true)
#@time yields, error_cusips = Preprocess.bond_values(gdf; treasury=false, debug=false)

partitions = [gdf[1 + Int(ceil(i*length(gdf)/n_splits)) : Int(ceil((i+1)*length(gdf)/n_splits)) ] for i in 0:n_splits-1]
@time res = pmap(x->Preprocess.bond_values(x, treasury=false), partitions)
yields = vcat([res[i][1] for i in 1:length(res)]...)
CSV.write("scripts/scientific_replication/data/warga_ice_risk_measures.csv", yields)

# Get dates
coups, dates, error_cusips = Preprocess.bond_dates(gdf)
CSV.write("scripts/scientific_replication/data/date_vectors_warga_ice.csv", dates)
CSV.write("scripts/scientific_replication/data/dates_warga_ice.csv", coups)

df = Preprocess.get_coupon_schedule(df, date_path="scripts/scientific_replication/data/dates_warga_ice.csv")
@rsubset!(df, :date.>=:offering_date)  # Some cusips have offering dates years after the day they are trading
df = add_temporal_features(df, trace=false)

# Add yield to data
gsw = CSV.read("scripts/scientific_replication/data/gsw.csv", DataFrame)
yields = CSV.read("scripts/scientific_replication/data/warga_ice_risk_measures.csv", DataFrame)
df1 = innerjoin(df, yields, on=[:date, :cusip])
leftjoin!(df1, gsw, on=:date)

transform!(df1, AsTable(:) => ByRow(x-> Preprocess.price_coupon_treasury(x.coupon, x.remcoup, x.interest_frequency, x.tmt, x.time_next_coup, x.beta0, x.beta1, x.beta2, x.beta3, x.tau1, x.tau2)) => :price_ctreasury )
df1.yield .= coalesce.(df1.yield, df1.yield_warga)

select!(df1, Not(Cols(startswith("beta"))))
select!(df1, Not(Cols(startswith("tau"))))

CSV.write("scripts/scientific_replication/data/warga_ice.csv", df1)

######################################################################3

### TREASURY RISK MEASURES ###
df1 = CSV.read("scripts/scientific_replication/data/warga_ice.csv", DataFrame)
gdf = groupby(df1, :cusip, sort=true)
#@time rf_yields, _ = Preprocess.bond_values(gdf, treasury=true)
partitions = [gdf[1 + Int(ceil(i*length(gdf)/n_splits)) : Int(ceil((i+1)*length(gdf)/n_splits)) ] for i in 0:n_splits-1]
@time res1 = pmap(x->Preprocess.bond_values(x, treasury=true), partitions)
rf_yields = vcat([res1[i][1] for i in 1:length(res1)]...)

CSV.write("scripts/scientific_replication/data/treasury_risk_measures_warga_ice.csv", rf_yields)

# Add to main data
rf_yields = CSV.read("scripts/scientific_replication/data/treasury_risk_measures_warga_ice.csv", DataFrame)
df1 = leftjoin(df1, rf_yields[:, Not(:coupacc1)], on=[:cusip, :date])
transform!(df1, [:yield, :yield_rf] => ByRow((y, y_rf)-> y-y_rf) => :yield_spread)
df1 = Preprocess.add_treasury_returns(df1)

CSV.write("scripts/scientific_replication/data/warga_ice_full.csv", df1)

#####################################################################

### Add TRACE to sample  ###
out = CSV.read("scripts/scientific_replication/data/warga_ice_full.csv", DataFrame)
bonds = CSV.read("scripts/scientific_replication/data/bonds_full.csv", DataFrame)
transform!(bonds, :rating_num=>ByRow(x->rating_conversion[round(x)])=>:rating) 
dropmissing!(bonds, :rating_num)
subset!(bonds, :rating_num=> ByRow(x-> ismissing(x) || x .<=22.))  # Remove non-missing values with rating at or above 22 (D)
sort!(bonds, [:cusip, :date])
bonds.source .= "trace"
@subset!(bonds, :date.>Date(2002,7,31), :date.<=Date(2023,12,31))
@subset!(out, :date.<=Date(2002,7,31))

cols_non_overlapping = [:yield_warga, :industry, :last_trade_date_val]
df = vcat(out[!, Not(cols_non_overlapping)], select(bonds, names(out[!, Not([:yield_warga, :industry, :last_trade_date_val, :coupacc1])])), cols=:union)

# df = vcat(select(bonds, names(out[!, Not(cols_non_overlapping)])), out[!, Not(cols_non_overlapping)])
# all_dups_from_trace = df[nonunique(df, [:cusip, :date]), :] |> x-> nrow(@subset(x, :source.=="trace")) == 0
# all_dups_from_trace || error("Removing duplicates from TRACE - all duplicates should be from ICE")    
# df = df[.!nonunique(df[!, [:date, :cusip]]), :]    
subset!(df, :bond_type=>ByRow(x->x ∉ ["FGOV", "ADEB", "ASPZ", "PS", "USBD", "USNT", "AMTN", "USSI", "USTC", "USSP", "MBS", "TXMU"]))
sort!(df, [:cusip, :date])

### FACTOR REGRESSORS ###
factor_regressors = Pfs.FactorRegressor(df).factor_regressors
replace_nans!(factor_regressors); dropmissing!(factor_regressors, :market)
CSV.write("scripts/scientific_replication/data/factor_regressors_warga_trace.csv", factor_regressors)


# Add value signal
tmp_ret_vol = Pfs.compute_rolling_signals(df, factor_regressors, Dict(:ret_vol=>x->Factors.vol(x, col=:ret_exc)); level=:cusip, window=12, min_window=6)
leftjoin!(df, tmp_ret_vol, on=[:date, :cusip])

transform!(df, :yield_spread => ByRow(x-> ismissing(x) || x<0. ? missing : x), renamecols=false)  # Set negative yield spreads to missing
transform!(df, [:yield_spread, :duration, :rating_num, :ret_vol] .=> ByRow(x->log(x)) .=> (x->x*"_log"))
df.value = missings(Float64, nrow(df))
gdf = groupby(df, :date)
transform(gdf) do sdf
    Factors.value(sdf, y=:yield_spread_log, x=["duration_log", "rating_num_log", "ret_vol_log"])
    return sdf
end

# Add permno
select!(df, Not(["permno"]))
df1 = @subset(df, :date.<=Date(2002, 7, 31)) |> x-> add_permno(x; link_period="warga")
df2 = @subset(df, :date.>Date(2002, 7, 31)) |> x-> add_permno(x; link_period="trace")
df = vcat(df1, df2, cols=:union); df1 = df2 = nothing

CSV.write("scripts/scientific_replication/data/warga_ice_trace.csv", df)

### TMP - TO BE DELETED ####
#bonds_full = CSV.read("scripts/scientific_replication/data/bonds_full.csv", DataFrame)
#yields = CSV.read("scripts/scientific_replication/data/warga_ice_risk_measures.csv", DataFrame)

# df = copy(df)
# df = antijoin(df, res, on=[:cusip, :date])
# gdf = groupby(df, :cusip; sort=true)
# @time res1, error_cusips = Preprocess.bond_values(gdf; debug=false)
# res2 = vcat(res1, res)
# res2 = unique(res2, [:date, :cusip])
# CSV.write("scripts/scientific_replication/data/warga_ice_risk_measures.csv", res2)

# yields = CSV.read("scripts/scientific_replication/data/warga_ice_risk_measures.csv", DataFrame)
# df = innerjoin(out, yields, on=[:date, :cusip])
# rf_yields = CSV.read("scripts/scientific_replication/data/treasury_risk_measures_warga_ice.csv", DataFrame)
# df = leftjoin(df, rf_yields[!, Not(:coupacc1)], on=[:cusip, :date])
# df = Preprocess.yield_spread_treasury_ret(df)  # Yield + Duration

# CSV.write("scripts/scientific_replication/data/warga_ice.csv", df)
### TMP - TO BE DELETED ###