"""
    create_factor_data.jl

Create factor regressors and bond factor returns.

This script should be run AFTER create_datasets.jl has completed.
It creates:
- Factor regressors (market, size, value, etc.)
- BBW-style factors (VaR, liquidity betas)
- Value signals based on yield spreads

Usage:
    julia --project=. scripts/create_factor_data.jl

Required input files (from create_datasets.jl):
- data/output/trace_daily.pq
- data/output/bonds_full.csv

Output files:
- data/output/factor_regressors.csv
- data/output/factor_regressors_bbw.csv
- data/output/bonds_full.csv (updated with value signals and equity links)
"""

using DataFramesMeta, Dates, CSV, Parquet
using ShiftedArrays: lag, lead

# Load modules
include("../src/main.jl")
include("utils_clean_data.jl")

println("\n" * "="^80)
println("Creating Factor Data")
println("="^80 * "\n")

# ============================================================================
# Load Data
# ============================================================================

println("[1/5] Loading data...")
trace_daily = DataFrame(read_parquet("data/output/trace_daily.pq")) |> year_month_day_to_date!
bonds = CSV.read("data/output/bonds_full.csv", DataFrame)
transform!(bonds, :rating_num=>ByRow(x->ceil(x)), renamecols=false)
dropmissing!(bonds, :rating_num)
subset!(bonds, :rating_num=> ByRow(x-> ismissing(x) || x .<=22.))  # Remove non-missing values with rating at or above 22 (D)
sort!(bonds, [:cusip, :date])
println("✓ Data loaded successfully")

# ============================================================================
# Create Factor Regressors
# ============================================================================

println("\n[2/5] Creating factor regressors (market, size, value, etc.)...")
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

# ============================================================================
# Add Value Signal
# ============================================================================

println("\n[4/5] Computing value signals based on yield spreads...")
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
println("✓ Value signals computed successfully")

# ============================================================================
# Add Equity Links and Save Final Dataset
# ============================================================================

println("\n[5/5] Adding equity links (PERMNO) and saving final dataset...")
select!(bonds, Not(["permno", "permco"]))
bonds = add_permno(bonds; link_period="trace")
CSV.write("data/output/bonds_full.csv", bonds)
println("✓ Final bond dataset saved to data/output/bonds_full.csv")

println("\n" * "="^80)
println("Factor Data Creation Complete!")
println("="^80)
println("\nOutput files:")
println("  - data/output/factor_regressors.csv")
println("  - data/output/factor_regressors_bbw.csv")
println("  - data/output/bonds_full.csv (updated)")
println()
