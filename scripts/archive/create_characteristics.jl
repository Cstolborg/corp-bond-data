# This file creates characteristics used to estimate factor returns.
# Each characteristic is computed in a way where a high value corresponds to the long portfolio and a low value the short portfolio
# E.g. for reversal signals, the sign of returns are flipped so that you go long high negative returns.
using DataFramesMeta, Dates, CSV, Parquet
using GLM
using Statistics
using StatsPlots
using StatsBase
using SASLib
using ShiftedArrays: lead, lag
gr(size=(1200, 700))


include("../../src/main.jl")
include("../utils/utils_clean_data.jl")
include("../../config/update_config.jl")


# Bond data
bonds = CSV.read("data/output/bonds_full.csv", DataFrame)
illiq = CSV.read("data/output/illiq.csv", DataFrame)
leftjoin!(bonds, illiq, on=[:cusip, :date=>:eom])
factor_regressors = CSV.read("data/output/factor_regressors_bbw.csv", DataFrame)

# Merge equity return onto bonds - used for equity mometum
stocks = CSV.read("data/wrds/stocks.csv", DataFrame) |> dropmissing
rename!(stocks, :id=>:permno, :eom=>:date)
@transform!(stocks, :date=Date.(string.(:date), "yyyymmdd"))
leftjoin!(bonds, stocks, on=[:date, :permno], matchmissing=:equal)

# Firm data
numcols = [:price_eom, :ret_eom, :ret_exc, :ret_exc_lead, :ret_texc_lead, :ret_eq, :value, :illiq, :rating_num, :MV, :amount_outstanding, :MV_lag, :MV_lead, :duration, :tmt, :convexity, :bond_age_pct, :bm, :yield_spread, :yield]
#numcols = [:price_eom, :ret_eom, :ret_exc, :ret_exc_lead, :ret_exc_lead2, :ret_texc_lead, :ret_eq, :illiq, :rating_num, :MV, :amount_outstanding, :duration, :tmt, :convexity, :bond_age_pct, :bm, :yield_spread, :yield, :MV_lag]

firms = Preprocess.compute_firm_ret(bonds, numcols; firm_id=:permno, duration_adjust=true)
#firms_nda = Preprocess.compute_firm_ret(bonds, numcols; firm_id=:permno, duration_adjust=false)

### DEFINE SIGNAL FUNCTIONS TO APPLY ###
rolling_signal_functions = Dict(
    :VaR5 => Factors.VaR,
    :VaR10 => x->Factors.VaR(x; VaR_n_obs=4),
    :expected_shortfall => Factors.expected_shortfall,
    #:mkt_beta => Factors.capm_bond_betas,
    :def_beta => Factors.def_beta,
    :term_beta => Factors.term_beta,
    :vol => Factors.vol,
    :skew => Factors.skew,
    :systematic_risk => Factors.systematic_risk,
    #:idiosyncratic_risk => Factors.idiosyncratic_risk,
    :vix_beta => Factors.vix_beta,
    :liq_beta => Factors.liquidity_betas
    )

tech_signal_functions = (
    # Momentum
    x -> Factors.momentum1(x, period=(1, 3), min_obs=nothing),
    x -> Factors.momentum1(x, period=(1, 6), min_obs=5),
    x -> Factors.momentum1(x, period=(1, 9), min_obs=8),
    x -> Factors.momentum1(x, period=(1, 12), min_obs=11),
    # Equity-Momentum
    x -> Factors.momentum1(x, ret_col=:ret_eq, period=(1, 6), min_obs=5),
    # Reversal
    x -> Factors.short_term_rev(x),
    x -> Factors.long_term_rev(x, period=(12, 48), min_obs=34),
            )

### SIGNALS ###
fsignals = compute_signals(firms, factor_regressors, rolling_signal_functions, tech_signal_functions; level=:permno)
#fsignals_nda = compute_signals(firms_nda, factor_regressors, rolling_signal_functions, tech_signal_functions; level=:permno)
signals = compute_signals(bonds, factor_regressors, rolling_signal_functions, tech_signal_functions; level=:cusip)


CSV.write("scripts/scientific_replication/data/signals.csv", signals)
CSV.write("scripts/scientific_replication/data/fsignal.csv", fsignals)
#CSV.write("scripts/scientific_replication/data/fsignal_nda.csv", fsignals_nda)






### OLD ###

# tmp = select(signals, :cusip, :date, :ret_exc_lead, :Value, Symbol("Long Term Reversal"), "Equity Momentum", "3m. Momentum", "6m. Momentum", "VaR(5%)")
# @subset!(tmp, Date(1984,6,30).<= :date .<= Date(1985,12,31))
# tmp2 = combine(groupby(tmp, :date), Cols(Between(2,8)) .=> (x->count(!ismissing, x))) |> x->sort(x, :date)
# @df tmp2 plot(:date, cols(3:8))



# # CORRELATION
# returns_bi, returns_bi_all = Pfs.factor_pipeline(signals, factor_regressors; double_sort=:rating, N_sorts=3, get_returns=true)
# tmp = Pfs.residual_reg(returns_bi, factor_regressors, x=["market", "term"])

# corr_ = cor(tmp)
# round.(corr_, digits=2)
# heatmap(corr_, x=names(tmp), y=names(tmp))

# using TexTables
# to_tex(corr_)

# ##### DEBUGGING BELOW ###############
# char_pf = :ret_6_1
# N_sorts = 2
# is_cut=false

# value_weight == true ? ret_col = :ret_vw : ret_col = :ret_ew
# # Check whether char is already cut into groups or not
# if is_cut == true
#     char_pf = string(char_pf)[4:end]  # strip string of pf_
#     df = dropmissing(signals, [char_pf])
# else
#     df = dropmissing(df, [char_pf])
#     transform!(groupby(df, :date), char_pf => (x->levelcode.(cut(x, N_sorts))), renamecols=false)
# end


# nmissing_pct_last_date = @subset(df, :date .== maximum(:date)) |> x-> count(ismissing, x.ret_exc) / length(x.ret_exc)



# pfs = combine(groupby(df, [:date, char_pf]),
#                 #[:ret_exc, :MV_lag] => ((ret, mv) -> sum(skipmissing(ret .* mv)) / sum(skipmissing(mv)) ) => :ret_vw,
#                 :ret_exc => mean ∘ skipmissing => :ret_ew, 
#                 [:ret_exc] => length => :N,
#                 :ret_exc => (x->count(ismissing, x)) => :nmissing,
#                 :MV_lag => (x->count(ismissing, x) / length(x)) => :nmissing_MV,
#                 #[:tmt, :MV_lag, char] .=> mean ∘ skipmissing, 
#                 renamecols=false)
# sort(pfs, :nmissing_MV)
# rename!(pfs, char_pf => :pf)
# sort!(pfs, [:date, :pf])
# transform!(pfs, [:N, :nmissing] => ((N, nmissing)->mean.(nmissing./N)) => :missing_pct)
# subset!(pfs, ret_col => ret -> .!isnan.(ret))

# # Create long-short portfolio
# lms = unstack(pfs, :date, :pf, ret_col)
# select!(lms, :date, ["1", string(N_sorts)] => ByRow((s, l)-> l-s) => char_pf)  # long minus short

# # Merge long-short back onto pfs
# #lms1 = stack(lms, char_pf, variable_name=:pf, value_name=ret_col)
# #pfs = vcat(pfs, lms1, cols=:union)
# pfs.factor .= char_pf




# cusip = "92343VBE3"
# cusip = "001765AE6"
# issue_id = 534351.0

# @subset(trace_month, :cusip .== cusip) |> x-> calendar_fill(x, date_col=:date, expand_obs_one_month=true)

# bonds = Preprocess.compute_bond_returns(trace_month, fisd, rf; min_tmt=1.)
# df = sort(select(@subset(bonds, :cusip .== cusip), :cusip, :date, :price_eom, :coupmonth, :maturity, :ret_eom, :ret_exc_lead, :coupacc, :coupamt, :MV, :MV_lag, :), :date)




# #### DOUBLE SORT DEBUGGIN ####

# value_counts(bonds, :rating_num)

# include("../../src/main.jl")
# df = copy(select(signals, 1:8, :rating))
# char_pf = :Duration

# last_ret_date = df[!, [:date, :ret_exc_lead]] |> dropmissing |> x->maximum(x.date)
# nmissing_pct_last_date = @subset(df, :date .== last_ret_date) |> x-> count(ismissing, x.ret_exc_lead) / length(x.ret_exc_lead)
# nmissing_pct_last_date > 0.99 ? @subset!(df, :date .< last_ret_date) : nothing
# ret_col = :ret_vw
# # Check whether char is already cut into groups or not
# char_name = string(char_pf)
# df = dropmissing(df, [char_pf])
# transform!(groupby(df, :date), char_pf => (x->levelcode.(cut(x, 3, allowempty=true)))=>string(char_pf)*"pf")
# char_pf = string(char_pf)*"pf"

# df = dropmissing(df, :rating)
# tmp1 = Pfs.sort_pfs(df, char_pf, char_name; double_sort=:rating)


# include("../../src/main.jl")
# N_sorts=3
# char_pf = :Duration
# char_name = string(char_pf)
# char_pf = string(char_pf)*"pf"

# df = copy(select(signals, 1:8, :rating))
# tmp1, tmp2 = Pfs.compute_characteristic_pfs(df, :Duration; double_sort=nothing, is_cut=false, N_sorts=3)
# tmp11, tmp22, tmp3 = Pfs.compute_characteristic_pfs(df, :Duration; double_sort=:rating, is_cut=false, N_sorts=3)


# tmp1
# tmp11
# tmp2
# tmp22

# combine(groupby(tmp, :rating)) do sdf
#     sdf = unstack(sdf, :date, :pf, :ret_vw)
#     select(sdf, :date, ["1", string(N_sorts)] => ByRow((s, l)-> l-s) => char_name)  # long minus short
# end
# sort!(tmp3, [:rating, :date])

# tmp33 = unstack(tmp3, :date, :rating, char_name; renamecols=x->char_name*"_"*x)
# select(tmp33, :date, AsTable(Cols(startswith(char_name)))=>ByRow(mean ∘ skipmissing)=>char_name)

