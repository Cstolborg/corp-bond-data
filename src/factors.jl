"""
    factors.jl

Factor computation functions extracted from src/factors/main.jl (Factors module)
"""

using DataFrames
using DataFramesMeta
using Dates
using GLM
using Statistics
using StatsBase
using RCall
using ShiftedArrays: lag

# Include local utilities
# Note: data_loader.jl functions are imported via main.jl (DataLoader module)

# ============================================================================
# AGE FACTORS
# ============================================================================

"""
    age_percent(df)

Calculate bond age as percentage of time to maturity.
Returns fraction of bond life that has expired.
"""
function age_percent(df)
    return 1. .- df.tmt ./ (Dates.value.(df.maturity .- df.offering_date) ./ 365)
end

# ============================================================================
# VALUE FACTORS
# ============================================================================

"""
    value(df; x::Vector{String}=["duration_log", "rating_num_log", "ret_vol_log"], y=:yield_spread_log, min_window=6, debug=false)

Empirical measure of value as used in Israel, Palhares, Richardson (2018).
Computes value as residual from cross-sectional regression of yield spread on duration, rating, and volatility.
"""
function value(df; x::Vector{String}=["duration_log", "rating_num_log", "ret_vol_log"], y=:yield_spread_log, min_window=6, debug=false)
    if nrow(dropmissing(df, vcat(x, string(y)))) < min_window
        return (; coefs=missing, coef_se=missing, coef_names=missing)
    end
    m = lm(Term(Symbol(y)) ~ sum(Term.(Symbol.(x))), df)

    if debug == true
        return (; coefs=Ref(coef(m)), coef_se=Ref(stderror(m)), coef_names=Ref(coefnames(m)))
    end

    df.value = df[!, y] .- predict(m, df)
end

"""
    book_to_market(df)

Calculate book-to-market ratio (face value / price).
"""
function book_to_market(df)
    return 100. ./ df.price_eom
end

# ============================================================================
# VALUE-AT-RISK (VaR)
# ============================================================================

"""
    VaR_full(df; window=36, min_window=24)

Compute 36-month rolling Value-at-Risk as second lowest return in rolling window.
"""
function VaR_full(df; window=36, min_window=24)
    df = sort(df, [:cusip, :date])
    start_date = lastdayofmonth(minimum(df.date)+Month(window)) # First day with a signal
    df = combine(groupby(df, :cusip)) do sdf
        res = DataFrame()
        if nrow(sdf) < min_window
            return res
        elseif nrow(sdf) < window
            window_l = nrow(sdf)
        else
            window_l = window
        end
        VaR_n_obs = 2  # Which observation is the 5% lowest

        for t in window_l:nrow(sdf)
            date = sdf[t, :date]
            date_min = date - Dates.Month(window_l)

            ret_rolling = subset(sdf, :date => x-> date_min .<= x .<= date)[!, :ret_exc]
            if length(ret_rolling) < min_window
                continue
            else
                VaR = ret_rolling[partialsortperm(ret_rolling, VaR_n_obs)] * -1.  # Change sign for interpretability
                push!(res, (;date=date, VaR=VaR))
            end
        end
        return res
    end
    @subset!(df, start_date .<= :date)
    return df
end

"""
    VaR(df; col=:ret_exc, VaR_n_obs=2)

Calculate Value-at-Risk as the second lowest return (5th percentile approximation).
"""
VaR(df; col=:ret_exc, VaR_n_obs=2) = df[!, col][partialsortperm(df[!, col], VaR_n_obs)] * -1.

"""
    expected_shortfall(df; col=:ret_exc, n_obs=4)

Calculate expected shortfall (average of worst returns).
"""
expected_shortfall(df; col=:ret_exc, n_obs=4) = mean(df[!, col][partialsortperm(df[!, col], 1:n_obs)]) * -1.

# ============================================================================
# VOLATILITY
# ============================================================================

"""
    vol(df; col=:ret_eom)

Calculate return volatility (standard deviation).
"""
function vol(df; col=:ret_eom)
    res = std(skipmissing(df[!, col]))
    if isnan(res)
        println(first(df[!, [:date, :cusip, col]], 20))
        error("NaN's when computed volatility")
    end
    return res
end

"""
    vix_beta(df; full_model=false)

Calculate VIX beta from regression on market factors.
"""
function vix_beta(df; full_model=false)
    model = lm(@formula(ret_exc ~ 1+mktrf+smb+hml+def+term+amh_liq_vol+vix+vix_lag), df)
    if full_model==true
        out = (;intercept=coef(model)[1], mkt=coef(model)[2], smb=coef(model)[3],
                hml=coef(model)[4], def=coef(model)[5], term=coef(model)[6], amh_liq=coef(model)[7], vix=coef(model)[8]+coef(model)[9])
    else
        out = coef(model)[8]+coef(model)[9]  # vix + lagged vix beta
    end
    return out
end

"""
    volatility(trace_daily, bonds)

Compute market-wide volatility measure from daily TRACE data.
"""
function volatility(trace_daily, bonds)
    df = bonds
    cusips = df[:, [:cusip, :date]] |> unique
    trace_daily.eom .= lastdayofmonth.(trace_daily.date)
    trace_daily_matched_cusips = innerjoin(trace_daily, cusips, on=[:cusip, :eom=>:date])
    trace_daily_matched_cusips = dropmissing(trace_daily_matched_cusips, :ret)
    subset!(trace_daily_matched_cusips, :ret =>ByRow(x->!isnan(x)))

    # Compute market value of sample
    mkt_val = combine(groupby(df, :date), :MV_lag => sum∘skipmissing, renamecols=false) |> x-> sort(x, :date)
    mkt_val = select(mkt_val, :date, :MV_lag => (x->lag(x, -1)) => :MV) |> dropmissing

    mkt_liq_non_traded = vol_amihud_non_traded(trace_daily_matched_cusips, mkt_val; verbose=false)
    return mkt_liq_non_traded
end

"""
    vol_amihud_non_traded(df, mkt_val; verbose=false)

Compute market-wide liquidity factor as in Lin et al. (2011).
"""
function vol_amihud_non_traded(df, mkt_val; verbose=false)
    df.eom = lastdayofmonth.(df.date)
    df.absret_vol = abs.(df.ret) ./ df.volume
    df = combine(groupby(df, [:eom, :cusip]), :absret_vol => mean => :illiq)

    # Winsorize illiq cross-sectionally month-by-month
    transform!(groupby(df, :eom), :illiq => (x-> collect(winsor(x, prop=0.01))) => :illiq)
    df = combine(groupby(df, :eom), :illiq => mean => :illiq)

    # Create additional explanatory variables as in Lin et al. (2011)
    leftjoin!(df, mkt_val, on=[:eom => :date])
    df = dropmissing(df, :MV)

    @transform!(df, :mkt_index = :MV ./ :MV[1], :illiq_diff = :illiq .- lag(:illiq, 1))
    @transform!(df, :delta_illiq = :mkt_index .* :illiq_diff)

    @transform!(df, :delta_illiq_lag = lag(:delta_illiq, 1),
                    :illiq_lag_scaled = lag(:MV, 1) ./ :MV[1] .* lag(:illiq, 1))
    df = dropmissing(df)
    df = sort(df, :eom)

    # Extract liquidity factor as the residual in an ARMAX regression
    df = vol_armax_amihud(df)
    df.amh_liq_vol = df.resid .*(-1.) ./ std(df.resid)

    if verbose == true
        return df
    else
        return df[:, [:eom, :amh_liq_vol]]
    end
end

"""
    vol_armax_amihud(df)

Estimate an ARMAX model using R to get the Amihud liquidity measure.
"""
function vol_armax_amihud(df)
    @rput df
    R"""
    x = df[, c("delta_illiq_lag", "illiq_lag_scaled")]
    model = arima(df[, "delta_illiq"], xreg=x, order = c(0,0,2))
    resid = residuals(model)
    """
    df.resid = @rget resid
    return df
end

"""
    rolling_vol_betas(df; window=60, min_window=10)

Rolling window estimation of volatility betas.
"""
function rolling_vol_betas(df; window=60, min_window=10)
    df = sort(df, [:cusip, :date])
    df = combine(groupby(df, :cusip)) do sdf
        res = DataFrame()
        if nrow(sdf) < min_window
            return res
        elseif nrow(sdf) < window
            window_l = nrow(sdf)
        else
            window_l = window
        end

        for t in window_l:nrow(sdf)
            date = sdf[t, :date]
            date_min = date - Dates.Month(window_l)

            df_rolling = subset(sdf, :date => x-> date_min .<= x .< date)
            if nrow(df_rolling) < min_window
                continue
            else
                out = vix_beta(df_rolling)
                push!(res, (;date=date, vix=out.vix))
            end
        end
        return res
    end
    return df
end

# ============================================================================
# LIQUIDITY FACTORS
# ============================================================================

"""
    liquidity_betas(df; full_model=false)

Calculate liquidity beta from regression on market factors.
"""
function liquidity_betas(df; full_model=false)
    model = lm(@formula(ret_exc ~ 1+mktrf+smb+hml+def+term+amh_liq), df)
    if full_model == true
        out = (;intercept=coef(model)[1], mkt=coef(model)[2], smb=coef(model)[3],
                hml=coef(model)[4], def=coef(model)[5], term=coef(model)[6], amh_liq=coef(model)[7])
    else
        out = coef(model)[7]
    end
    return out
end

"""
    liquidity_amihud_regressor(trace_daily, bonds)

Compute liquidity factor from daily TRACE data using Amihud measure.
"""
function liquidity_amihud_regressor(trace_daily, bonds)
    df = bonds
    cusips = df[:, [:cusip, :date]] |> unique
    trace_daily.eom .= lastdayofmonth.(trace_daily.date)
    trace_daily_matched_cusips = innerjoin(trace_daily, cusips, on=[:cusip, :eom=>:date])
    trace_daily_matched_cusips = dropmissing(trace_daily_matched_cusips, :ret)
    subset!(trace_daily_matched_cusips, :ret =>ByRow(x->!isnan(x)))

    # Compute market value of sample
    mkt_val = combine(groupby(df, :date), :MV => sum∘skipmissing, renamecols=false) |> x-> sort(x, :date)

    mkt_liq_non_traded = liquidity_amihud_non_traded(trace_daily_matched_cusips, mkt_val; verbose=false)
    return mkt_liq_non_traded
end

"""
    liquidity_amihud_non_traded(df, mkt_val; verbose=false)

Compute market-wide liquidity factor as in Lin et al. (2011).
"""
function liquidity_amihud_non_traded(df, mkt_val; verbose=false)
    df.eom = lastdayofmonth.(df.date)
    df.absret_vol = abs.(df.ret) ./ df.volume
    df = combine(groupby(df, [:eom, :cusip]), :absret_vol => mean => :illiq)

    # Winsorize illiq cross-sectionally month-by-month
    transform!(groupby(df, :eom), :illiq => (x-> collect(winsor(x, prop=0.01))) => :illiq)
    df = combine(groupby(df, :eom), :illiq => mean => :illiq)

    # Create additional explanatory variables as in Lin et al. (2011)
    leftjoin!(df, mkt_val, on=[:eom => :date])
    df = dropmissing(df, :MV)

    @transform!(df, :mkt_index = :MV ./ :MV[1], :illiq_diff = :illiq .- lag(:illiq, 1))
    @transform!(df, :delta_illiq = :mkt_index .* :illiq_diff)

    @transform!(df, :d1 = ifelse.(:eom .== Date(2003, 3, 31), 1., 0.),  # Dummy for March 2003
                    :d2 = ifelse.(:eom .== Date(2004, 10, 31), 1., 0.), # Dummy for October 2004
                    :delta_illiq_lag = lag(:delta_illiq, 1),
                    :illiq_lag_scaled = lag(:MV, 1) ./ :MV[1] .* lag(:illiq, 1))
    df = dropmissing(df)
    df = sort(df, :eom)

    # Extract liquidity factor as the residual in an ARMAX regression
    println("Estimating Amihud liquidity regression...")
    println("Number of observations: ", nrow(df))
    println(first(df, 10))
    df = armax_amihud(df)
    df.amh_liq = df.resid .*(-1.) ./ std(df.resid)

    if verbose == true
        return df
    else
        return df[:, [:eom, :amh_liq]]
    end
end

"""
    armax_amihud(df)

Estimate an ARMAX model using R to get the Amihud liquidity measure.
"""
function armax_amihud(df)
    @rput df
    R"""
    x = df[, c("d1", "d2", "delta_illiq_lag", "illiq_lag_scaled")]
    model = arima(df[, "delta_illiq"], xreg=x, order = c(0,0,2))
    resid = residuals(model)
    """
    df.resid = @rget resid
    return df
end

"""
    rolling_liquidity_betas(df; window=60, min_window=15)

Rolling window estimation of liquidity betas.
"""
function rolling_liquidity_betas(df; window=60, min_window=15)
    df = sort(df, [:cusip, :date])
    df = combine(groupby(df, :cusip)) do sdf
        res = DataFrame()
        if nrow(sdf) < min_window
            return res
        end

        for t in min_window:nrow(sdf)
            date = sdf[t, :date]
            date_min = date - Dates.Month(window)

            df_rolling = subset(sdf, :date => x-> date_min .<= x .< date)
            if nrow(df_rolling) < min_window
                continue
            else
                out = liquidity_betas(df_rolling)
                push!(res, (;date=date, amh_liq=out.amh_liq))
            end
        end
        return res
    end
    return df
end

# ============================================================================
# MARKET FACTORS
# ============================================================================

"""
    market(df::AbstractDataFrame; dataset=nothing)

Compute bond market excess return as value-weighted average from TRACE sample.
"""
function market(df::AbstractDataFrame; dataset=nothing)
    transform!(df, [:ret_exc_lead, :MV] => ByRow((r, m)->!ismissing(r)*m)=>:MV_nonmissing)
    df = @chain df begin
        groupby(:date)
        @combine(:ret_exc = sum(skipmissing(:ret_exc_lead .* :MV_nonmissing), init=0.) / sum(skipmissing(:MV_nonmissing)), :MV_lag = sum(skipmissing(:MV_nonmissing))  )
        rename(:ret_exc => :mkt_bond, :MV_lag => :MVB_lag)
    end
    transform!(df, :date=>ByRow(x->lastdayofmonth(x .+ Month(1))), renamecols=false)
    df.factor .= "market"
    if dataset != nothing
        df.dataset .= dataset
    end
    df.mkt_bond = replace(df.mkt_bond, 0. => missing)
    dropmissing!(df, :mkt_bond)
    return df
end

"""
    market(source::String="BofA"; long_term_mkt=true)

Load BofA bond market return.
"""
function market(source::String="BofA"; long_term_mkt=true)
    source != "BofA" ? error("""Pass source="BofA" to load market return data from Bank of America index """) : 0
    df = load_BofA_market(long_term_mkt=long_term_mkt) |> x->rename(x, :ret_eom=>:mkt_bond)
    df.factor .= "market"
    return df
end

"""
    DEF()

Default factor as difference between long-term Corp-Bonds minus GOV10.
"""
function DEF()
    corp = load_BofA_market(long_term_mkt=true) |> x->rename(x, :ret_eom=>:mkt_bond)
    gov = load_long_term_gov() |> x->rename(x, :ret_eom=>:ret_gov)

    df = leftjoin(corp, gov, on=:date)
    @select!(df, :date, :ret_eom = :mkt_bond .- :ret_gov)
    dropmissing!(df)
    sort!(df, :date)
    df.factor .= "def"
    return df
end

"""
    TERM()

TERM factor as GOV10 minus one-month treasury.
"""
function TERM()
    gov = load_long_term_gov() |> x->rename(x, :ret_eom=>:ret_gov)
    rf = load_rf()

    df = leftjoin(gov, rf, on=:date)
    @select!(df, :date, :ret_eom = :ret_gov .- :rf)
    dropmissing!(df)
    sort!(df, :date)
    df.factor .= "term"
    return df
end

"""
    mkt_def_term(df)

Create market, DEF, and TERM factors from bond dataset.
"""
function mkt_def_term(df)
    mkt = market(df)  |> x->rename(x, :mkt_bond=>:ret_eom)
    def = DEF()
    term = TERM()

    df = vcat(mkt, def, term, cols=:union)
    df = unstack(df, :date, :factor, :ret_eom) |> x->dropmissing(x, :market)
    sort!(df, [:date])
    return df
end
