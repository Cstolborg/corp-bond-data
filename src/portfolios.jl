"""
    portfolios.jl

Portfolio construction, characteristic sorting, and factor return computation functions.
Extracted from corp-bond-replication/src/portfolios/
"""

using DataFrames
using DataFramesMeta
using Dates
using CategoricalArrays: cut, levelcode
using Statistics
using ProgressMeter

# ============================================================================
# FactorRegressor Struct
# ============================================================================

"""
    FactorRegressor

Struct to hold factor regressors (market, DEF, TERM, FF factors, VIX, liquidity).
Provides two constructors: one with liquidity factors, one without.

# Constructors
- `FactorRegressor(df, trace_daily)`: With liquidity factors from trace_daily
- `FactorRegressor(df)`: Without liquidity factors (simpler version)

# Returns
Struct with factor_regressors::AbstractDataFrame
"""
struct FactorRegressor
    factor_regressors:: AbstractDataFrame
    function FactorRegressor(df, trace_daily)
        factor_regressors = Factors.mkt_def_term(df)
        ff = DataLoader.load_ff()
        vix = DataLoader.load_vix()
        factor_regressors = leftjoin(factor_regressors, ff, on=:date)
        factor_regressors = leftjoin(factor_regressors, vix, on=:date)
        mkt_liq_non_traded = Factors.liquidity_amihud_regressor(trace_daily, df)
        mkt_liq_non_traded_vol = Factors.volatility(trace_daily, df)  # Market illiquidity measure
        factor_regressors = leftjoin(factor_regressors, mkt_liq_non_traded, on=[:date => :eom])
        factor_regressors = leftjoin(factor_regressors, mkt_liq_non_traded_vol, on=[:date => :eom])
        select!(factor_regressors, Not(:rf))
        sort!(factor_regressors, :date)
        return new(factor_regressors)
    end

    function FactorRegressor(df)
        factor_regressors = Factors.mkt_def_term(df)
        ff = DataLoader.load_ff()
        factor_regressors = leftjoin(factor_regressors, ff, on=:date)
        select!(factor_regressors, Not(:rf))
        sort!(factor_regressors, :date)
        return new(factor_regressors)
    end
end

# ============================================================================
# Rolling Signal Computation
# ============================================================================

"""
    compute_rolling_signals(df, factor_regressors, signal_functions; level=:cusip, window=36, min_window=24)

Compute rolling window signals for each bond using custom signal functions.

# Arguments
- `df`: Input DataFrame with bond returns and characteristics
- `factor_regressors`: DataFrame with market factors for each date
- `signal_functions`: Dict{Symbol, Function} mapping signal names to functions
- `level`: Grouping variable (default: :cusip)
- `window`: Rolling window length in months (default: 36)
- `min_window`: Minimum required observations (default: 24)

# Returns
DataFrame with cusip, date, and computed signals for each bond-month

# Example
```julia
signal_functions = Dict(
    :mkt_beta => df -> coef(lm(@formula(ret_exc ~ market), df))[2],
    :volatility => df -> std(df.ret_exc)
)
signals = compute_rolling_signals(bonds, factor_regressors, signal_functions)
```

# Note
Skips cusips with fewer than min_window observations.
For each time t, uses data from (t-window) to t.
"""
function compute_rolling_signals(df::AbstractDataFrame, factor_regressors::AbstractDataFrame, signal_functions::Dict; level=:cusip, window=36, min_window=24)
    if any(occursin.("def", names(df))) && any(occursin.("term", names(df)))
        select!(df, Not([:def, :term]))
    end
    df = leftjoin(df, factor_regressors, on=:date)  # Market, DEF, TERM etc.
    df = sort(df, [level, :date])
    start_date = lastdayofmonth(minimum(df.date)+Month(window-1)) # First day with a signal

    res = DataFrame(:id => Union{Missing, Int, Float64, String, String15}[], :date=>Date[], [name => Union{Missing, Float64}[] for name in names(signal_functions)]...)
    @showprogress for (key, sdf) in pairs(groupby(df, level))  # Loop through each cusip
        if nrow(sdf) < min_window  # Skip if too few obs
            continue
        end

        for t in min_window:nrow(sdf)
            date = sdf[t, :date]
            date_min = lastdayofmonth(date - Dates.Month(window))

            df_rolling = subset(sdf, :date => x-> date_min .< x .<= date, :ret_exc => x-> .!ismissing.(x))  # extract df that maximally goes window months back
            if nrow(df_rolling) < min_window
                continue
            end
            # Apply signal functions to data, save to namedtuple and push to res
            signals = Dict([x[1] => x[2](df_rolling) for x in signal_functions])
            signals = NamedTuple{Tuple(keys(signals))}(values(signals))  # Convert to NamedTuple
            try
                push!(res, (;id=key[level], date=date, signals...))
            catch e
                println(e)
                println(key, date)
                println(signals)
            end
        end
    end
    rename!(res, :id=>level)
    return res
end

"""
    apply_signal_function(signal_functions::Dict{Symbol, Function})

Helper function to apply multiple signal functions to rolling data.
Returns NamedTuple of computed signals.
"""
function apply_signal_function(signal_functions::Dict{Symbol, Function})
    signals = Dict([x[1] => x[2](df_rolling) for x in signal_functions])
    signals = NamedTuple{Tuple(keys(signals))}(values(signals))  # Convert to NamedTuple
end

# ============================================================================
# Factor Pipeline Functions
# ============================================================================

"""
    factor_pipeline(signals, factor_regressors; kwargs...)

Complete pipeline from signals to factor returns with optional double sorting.

# Arguments
- `signals`: DataFrame with bond characteristics/signals
- `factor_regressors`: DataFrame with market factor returns
- `double_sort`: Variable to double sort on (e.g., :rating), or nothing for single sort
- `N_sorts`: Number of portfolios to create (default: 3)
- `x`: Vector of regressor names for alpha computation
- `exclude`: Vector of signals to exclude from factor construction
- `first_sig_col`: Name of first signal column
- `get_returns`: If true, return portfolio returns instead of factor table
- `ret_holding`: Return column to use (default: :ret_exc_lead)
- `MV_col`: Market value column (default: :MV)
- `n_ahead`: Months ahead for returns (default: 1)
- `min_ret`: Minimum assets per portfolio (default: 10)
- `value_weight`: Use value weighting (default: true)

# Returns
- If get_returns=false: Factor table(s) with alphas and t-statistics
- If get_returns=true: (portfolios, factor_returns, factor_returns_double)
"""
function factor_pipeline(signals, factor_regressors; double_sort=:rating, N_sorts=3, x=["market", "term"], exclude::Vector=[Symbol("Credit Rating")], first_sig_col="Value",
                         get_returns=false, ret_holding=:ret_exc_lead, MV_col=:MV, n_ahead=1, min_ret=10, value_weight::Bool=true)
    if double_sort == nothing
        signal_names = select(signals, Between(first_sig_col, names(signals)[end])) |> names
        pfs, factor_returns = Pfs.compute_characteristic_pfs(signals,signal_names; double_sort=double_sort, is_cut=false, N_sorts=N_sorts, ret_holding=ret_holding,
                                                            MV_col=MV_col, n_ahead=n_ahead, min_ret=min_ret, value_weight=value_weight)
        res = Pfs.create_factor_table(factor_returns, factor_regressors; x=x)
        sort!(res, [:factor])
        return res
    else
        signal_names = select(signals, Between(first_sig_col, names(signals)[end])) |> x->select(x, Not([exclude...])) |> names
        pfs, factor_returns, factor_returns_double = Pfs.compute_characteristic_pfs(signals,signal_names; double_sort=double_sort, is_cut=false, N_sorts=N_sorts, ret_holding=ret_holding,
                                                                                    MV_col=MV_col, n_ahead=n_ahead, min_ret=min_ret, value_weight=value_weight)

        if get_returns==true
            return pfs, factor_returns, factor_returns_double
        end

        res = create_factor_table(factor_returns, factor_regressors; x=x)
        sort!(res, [:factor])
        if double_sort in [:cusip, :permno, :id]  # Don't compute alpha for each bond
            return res
        end

        res_double = create_factor_table(factor_returns_double, factor_regressors; x=x)
        sort!(res_double, [:factor])
        return res, res_double
    end
end

"""
    factor_pipeline_eq(signals, factor_regressors; kwargs...)

Factor pipeline specialized for equity factors with double sorting.
Similar to factor_pipeline but always returns both single and double-sorted results.
"""
function factor_pipeline_eq(signals, factor_regressors; double_sort=:rating, N_sorts=3, x=["market", "term"], exclude::Vector=[Symbol("Credit Rating")], first_sig_col="Value",
                         get_returns=false, ret_holding=:ret_exc_lead, MV_col=:MV, n_ahead=1, min_ret=10, value_weight::Bool=true)
    signal_names = select(signals, Between(first_sig_col, names(signals)[end])) |> names
    pfs, factor_returns, factor_returns_double = Pfs.compute_characteristic_pfs(signals,signal_names; double_sort=double_sort, is_cut=false, N_sorts=N_sorts, ret_holding=ret_holding,
                                                                                MV_col=MV_col, n_ahead=n_ahead, min_ret=min_ret, value_weight=value_weight)

    if get_returns==true
        return pfs, factor_returns, factor_returns_double
    end

    res = create_factor_table(factor_returns, factor_regressors; x=x)
    res_double = create_factor_table(factor_returns_double, factor_regressors; x=x)
    sort!(res, [:factor])
    sort!(res_double, [:factor])
    return res, res_double
end

# ============================================================================
# Characteristic Portfolio Construction
# ============================================================================

"""
    compute_characteristic_pfs(df, char_pf; kwargs...)

Create characteristic-sorted portfolios and compute long-short factor returns.

# Arguments
- `df`: Input DataFrame with characteristics and returns
- `char_pf`: Characteristic(s) to sort on (Symbol/String or Vector)
- `N_sorts`: Number of portfolios (default: 5)
- `double_sort`: Variable for conditional sorting (default: nothing)
- `is_cut`: Whether characteristic is already cut into portfolios
- `value_weight`: Use value weighting vs equal weighting
- `ret_holding`: Return column name (default: :ret_exc_lead)
- `MV_col`: Market value column (default: :MV)
- `n_ahead`: Months ahead for return realization (default: 1)
- `min_ret`: Minimum assets required per portfolio (default: 10)

# Returns
- Single characteristic: (portfolios, factor_returns)
- Multiple characteristics: (portfolios, factor_returns, factor_returns_double)
- With double_sort: (portfolios, factor_returns, factor_returns_double)

# Note
Automatically handles within-firm sorting when double_sort is :cusip, :permno, or :id
"""
function compute_characteristic_pfs(df::AbstractDataFrame, char_pf::Union{Vector{Symbol}, Vector{String}};
                                    double_sort=nothing, is_cut::Bool=false, N_sorts::Integer=5, value_weight::Bool=true,
                                    ret_holding=:ret_exc_lead, MV_col=:MV, n_ahead=1, min_ret=10)
    factor_returns, factor_returns_double, pfs = DataFrame(date=[]), DataFrame(date=[]), DataFrame(date=[])
    for name in char_pf
        println("Computing $name -- size of data is $(size(df))")
        if double_sort == nothing
            pfs_tmp, lms = Pfs.compute_characteristic_pfs(df, Symbol(name); double_sort=double_sort, is_cut=is_cut, N_sorts=N_sorts, value_weight=value_weight, ret_holding=ret_holding, MV_col=MV_col, n_ahead=n_ahead, min_ret=min_ret)
        else
            pfs_tmp, lms, lms_double = Pfs.compute_characteristic_pfs(df, Symbol(name); double_sort=double_sort, is_cut=is_cut, N_sorts=N_sorts, value_weight=value_weight, ret_holding=ret_holding, MV_col=MV_col, n_ahead=n_ahead, min_ret=min_ret)
            factor_returns_double = outerjoin(factor_returns_double, lms_double, on=:date)
        end
        factor_returns = outerjoin(factor_returns, lms, on=:date)
        pfs = vcat(pfs, pfs_tmp; cols=:union)
        end
    sort!(factor_returns, :date)
    sort!(pfs, [:date, :pf])

    if double_sort == nothing
        return pfs, factor_returns
    else
        sort!(factor_returns_double, :date)
        return pfs, factor_returns, factor_returns_double
    end
end

"""
    compute_characteristic_pfs(df, char_pf::Union{Symbol, String}; kwargs...)

Single characteristic version of portfolio sorting.
Sorts bonds into N_sorts portfolios based on characteristic at t,
computes value-weighted returns at t+1.

# Arguments
- `df`: Input DataFrame with bond characteristics and returns
- `char_pf`: Single characteristic to sort on
- `N_sorts`: Number of portfolios (default: 5, quintiles)
- `double_sort`: Optional second sort dimension (e.g., :rating, :permno)
- `is_cut`: Whether char_pf is already cut into portfolio labels
- `value_weight`: If true, use value weighting; if false, equal weighting
- `ret_holding`: Column with holding period returns (default: :ret_exc_lead)
- `MV_col`: Market value column for weighting (default: :MV)
- `n_ahead`: Number of months ahead for return measurement (default: 1)
- `min_ret`: Minimum number of bonds per portfolio (default: 10)

# Returns
- Without double_sort: (pfs, factor_returns)
- With double_sort: (pfs, factor_returns, factor_returns_double)

Where:
- `pfs`: Portfolio-level returns and statistics
- `factor_returns`: Long-short factor returns (high minus low)
- `factor_returns_double`: Factor returns within each double_sort group

# Note
When double_sort is :cusip/:permno/:id, performs within-firm sorting.
Requires at least 2 bonds per firm with variation in the characteristic.
"""
function compute_characteristic_pfs(df::AbstractDataFrame, char_pf::Union{Symbol, String};
                                    N_sorts::Integer=5, double_sort=nothing, is_cut::Bool=false,
                                    value_weight::Bool=true, ret_holding::Symbol=:ret_exc_lead, MV_col=:MV,
                                    n_ahead=1, min_ret=10)
    # Check for missing values and require there is at least some variation in signal
    df = dropmissing(df, [char_pf, MV_col])  # No missing in either market value or portfolio
    if double_sort in [:cusip, :permno, :id, :permno_rating]
        dropmissing!(df, [double_sort, :ret_exc_lead])  # Assume bond will trade in the next period
        @transform!(groupby(df, [:date, :permno]), :n_bonds=sum(.!ismissing.(:ret_exc_lead)))
        @subset!(df, :n_bonds.>1)

        # Ensure there is some variation within each firm
        @transform!(groupby(df, [:date, double_sort]), :std_val=std($(Symbol(char_pf))) )
        df.std_val = replace_nans(df.std_val, replace_val=0.0)
        @subset!(df, :std_val.>0.0)
    end

    # Check whether the last date has all NULL values
    last_ret_date = df[!, [:date, ret_holding]] |> dropmissing |> x->maximum(x.date)
    nmissing_pct_last_date = @subset(df, :date .== last_ret_date) |> x-> count(ismissing, x.ret_exc_lead) / length(x.ret_exc_lead)
    nmissing_pct_last_date > 0.99 ? @subset!(df, :date .< last_ret_date) : nothing

    value_weight==true ? ret_col = :ret_vw : ret_col = :ret_ew

    # Sort based on characteristic and double_sort
    df, char_pf, char_name = cut_chars(df, char_pf; get_sorts=false, N_sorts=N_sorts, double_sort=double_sort, is_cut=is_cut, MV_col=MV_col)

    # Create portfolios
    pfs = sort_pfs(df, char_pf, char_name; ret_holding=ret_holding, MV_col=MV_col, n_ahead=n_ahead, double_sort=double_sort, min_ret=min_ret)

    # Create long-short portfolio
    res = factor_returns(pfs, char_name; double_sort=double_sort, N_sorts=N_sorts, ret_col=ret_col)
    double_sort==nothing ? res =  (pfs, res) : res = (pfs, res...)   # Handle different number of return values
    return res
end

# ============================================================================
# Portfolio Cutting and Sorting Helpers
# ============================================================================

"""
    cut_chars(df, char_pf; kwargs...)

Cut characteristic into N_sorts equal-sized groups (quantile-based).

# Arguments
- `df`: Input DataFrame
- `char_pf`: Characteristic column to cut
- `get_sorts`: If true, return sort thresholds instead of cut data
- `N_sorts`: Number of groups to create (default: 5)
- `double_sort`: Variable to condition on when cutting (default: nothing)
- `is_cut`: Whether char_pf is already cut (default: false)
- `MV_col`: Market value column (default: :MV)

# Returns
- If get_sorts=false: (df, char_pf_name, char_name) with added portfolio column
- If get_sorts=true: DataFrame with portfolio thresholds by date (and double_sort)

# Note
When double_sort is :cusip/:permno/:id, uses within-firm cutting via cut_within_permno
"""
function cut_chars(df, char_pf; get_sorts=false, N_sorts=5, double_sort=nothing, is_cut=false, MV_col=:MV)
    double_sort == nothing ? date_char_cols = [:date] : date_char_cols = [:date, Symbol(double_sort)]  # groupby on either :date or date AND double_sort

    char_name = string(char_pf)

    if get_sorts==true
        transform!(groupby(df, [date_char_cols...]), char_pf => (x->cut(x, N_sorts, labels=fmt))=>string(char_pf)*"pf")
        transform!(df, Symbol(string(char_pf)*"pf")=>ByRow(x->parse.(Float64, split(String.(x), ",")))=>:intervals )
        transform!(df, :intervals=>ByRow(x->Int(x[1]))=>:pf)
        transform!(df, :intervals=>ByRow(x->x[3])=>:interval)
        df = unique(df, [:date, :rating, :pf])
        sort!(df, [:date, :rating, :pf])
        select!(df, :date, double_sort, :intervals, :interval, :pf)
        df = unstack(df, [date_char_cols...], :pf, :interval)
        select!(df, :date, :rating, Cols(string.(1:N_sorts))=>ByRow((x...)->[x...])=>:thresh)  # Combine all threshhold columns into one
        return df
    end

    # Cut char into groups if this is not done already
    if is_cut == false
        if double_sort in [:cusip, :permno, :id, :permno_rating]  # Add some noise to the signal to avoid ties in cut function
            transform!(groupby(df, [date_char_cols...]),
            char_pf =>(x->cut_within_permno(x))
            =>string(char_pf)*"pf"
            )
        else
            transform!(groupby(df, [date_char_cols...]), char_pf => (x->levelcode.(cut(x, N_sorts, allowempty=true, labels=fmt)))=>string(char_pf)*"pf")
        end
        char_pf = string(char_pf)*"pf"
    end
    return df, char_pf, char_name
end

"""
    cut_within_permno(x)

Cut signal within each firm into 3 equally sized pieces.
If only 2 unique values, splits into 2 groups.
If only 1 unique value, returns missing for all.

# Arguments
- `x`: Vector of characteristic values for one firm-date

# Returns
Vector of portfolio assignments (1, 2, or 3), or missing if no variation

# Note
Uses tertiles (1/3, 2/3 quantiles) for within-firm ranking.
"""
function cut_within_permno(x)
    x_uniq = unique(x)
    if length(x_uniq) < 2
        return [missing for i in x]
    end

    lower, upper = quantile(x_uniq, [1/3, 2/3])
    return [i<lower ? 1 : i>upper ? 3 : 2 for i in x]
end

"""
    sort_pfs(df, char_pf, char_name; kwargs...)

Aggregate individual bonds into portfolios and compute portfolio returns.

# Arguments
- `df`: DataFrame with portfolio assignments
- `char_pf`: Portfolio column name(s)
- `char_name`: Name of characteristic (for output)
- `ret_holding`: Return column to aggregate
- `MV_col`: Market value column for weighting (default: :MV)
- `n_ahead`: Months to shift dates forward (default: 1)
- `double_sort`: Optional second grouping variable
- `ret_col`: Return column to compute (default: :ret_vw)
- `min_ret`: Minimum bonds per portfolio (default: 10)

# Returns
DataFrame with portfolio-level statistics:
- ret_vw: Value-weighted return
- ret_ew: Equal-weighted return
- N: Number of bonds
- nmissing: Number of missing returns
- missing_pct: Percent of missing returns
- MV: Total market value
- factor: Characteristic name

# Note
Filters out portfolios with fewer than min_ret non-missing returns.
Adjusts dates by n_ahead months for proper timing.
"""
function sort_pfs(df, char_pf, char_name; ret_holding, MV_col=:MV, n_ahead=1, double_sort::Union{Nothing, Symbol}=nothing,
                    ret_col=:ret_vw, min_ret=10)
    if double_sort != nothing
        df = dropmissing(df, double_sort)
        char_pf = [Symbol(char_pf), double_sort]
    else
        char_pf=[Symbol(char_pf)]
    end
    transform!(df, [ret_holding, MV_col] => ByRow((r, m)->!ismissing(r)*m)=>:MV_nonmissing)
    pfs = combine(groupby(df, [:date, char_pf...]),
                    [ret_holding, :MV_nonmissing] => ((ret, mv) -> sum(skipmissing(ret .* mv), init=0.) / sum(skipmissing(mv)) ) => :ret_vw,
                    ret_holding => mean ∘ skipmissing => :ret_ew,
                    [ret_holding] => length => :N,
                    ret_holding => (x->count(ismissing, x)) => :nmissing,
                    ret_holding => (x->count(ismissing, x)/length(x)) => :missing_pct,
                    :MV_nonmissing => sum => :MV,
                    renamecols=false)
    char_pf = char_pf[1]
    rename!(pfs, char_pf => :pf)
    sort!(pfs, [:date, :pf])
    pfs = replace_nans(pfs)
    pfs.factor .= char_name

    # error checks
    if any((pfs.N .- pfs.nmissing) .< min_ret)
        less_than_10 = @subset(pfs, (:N .- :nmissing) .< min_ret)
        pct_less_than10 = round(nrow(less_than_10) / nrow(pfs) * 100., digits=2)
        println("There are $pct_less_than10 % Pfs with less than $min_ret assets in $char_name")
        println(first(less_than_10, 5))
        @subset!(pfs, (:N .- :nmissing) .>= min_ret)
    end
    missing_rets = subset(pfs, ret_col => ByRow(ret -> ismissing.(ret) || isnan.(ret)))
    nrow(missing_rets) == 0 || println("There are $(nrow(missing_rets)) missing returns in pfs out of $(nrow(pfs)) \n", first(missing_rets, 50))

    # Move date up n month so returns are recorded at time t
    transform!(pfs, :date=>ByRow(x->lastdayofmonth(x .+ Month(n_ahead))), renamecols=false)
    return pfs
end

# ============================================================================
# Factor Return Computation
# ============================================================================

"""
    factor_returns(pfs, char_name; kwargs...)

Compute long-short factor returns from sorted portfolios.

# Arguments
- `pfs`: Portfolio DataFrame from sort_pfs
- `char_name`: Name of characteristic
- `double_sort`: Optional grouping variable (e.g., :rating, :permno_rating)
- `N_sorts`: Number of portfolios (default: 5)
- `ret_col`: Return column to use (default: :ret_vw)

# Returns
- If double_sort=nothing: factor_returns DataFrame (date, long-short return)
- If double_sort specified: (factor_returns, factor_returns_double)

# Note
Long-short is portfolio N_sorts minus portfolio 1 (high minus low).
For :permno_rating double_sort, aggregates within-firm returns by rating group.
For other double_sorts, takes equal-weighted average across groups.

# Example
```julia
# Simple long-short
lms = factor_returns(pfs, "Value"; N_sorts=5)

# Double-sorted by rating
lms, lms_double = factor_returns(pfs, "Value"; double_sort=:rating, N_sorts=5)
```
"""
function factor_returns(pfs, char_name; double_sort=nothing, N_sorts=5, ret_col=:ret_vw)
    if double_sort == nothing
        lms = unstack(pfs, :date, :pf, ret_col)
        select!(lms, :date, ["1", string(N_sorts)] => ByRow((s, l)-> l-s) => char_name)  # long minus short
        sort!(lms, :date)
        return lms
    elseif double_sort==:permno_rating
        # Get long-short returns within each firm
        dropmissing!(pfs, :pf)
        lms_double = combine(groupby(pfs, double_sort)) do sdf
            sdf = unstack(sdf, :date, :pf, ret_col)
            select(sdf, :date, ["1", string(N_sorts)] => ByRow((s, l)-> l-s) => char_name)  # long minus short
        end

        # Get total market value of long+short for each firm
        mv_double = combine(groupby(pfs, double_sort)) do sdf
            sdf = unstack(sdf, :date, :pf, :MV)
            select(sdf, :date, ["1", string(N_sorts)] => ByRow((s, l)-> l+s) => "MV")  # MV of long+short
        end

        # Value weight each LS pf by firm MV
        leftjoin!(lms_double, mv_double, on=[:date, :permno_rating])
        @rtransform!(lms_double, :rating=:permno_rating[7:end])
        @assert nrow(lms_double) == nrow(@rsubset(lms_double, :rating in ["SG", "IG+", "IG-"]))  "Some permno's haven't had rating properly processed"
        lms_double = combine(groupby(lms_double, [:date, :rating]), [char_name, "MV"] => ((ret, mv)->mean_vw(ret, mv)) => char_name)

        # Unstack and get rating-specific portfolios as well as equal-weighted return over each rating group
        lms_double = unstack(lms_double, :date, :rating, char_name; renamecols=x->char_name*"_"*string(x))
        lms = select(lms_double, :date, AsTable(Cols(startswith(char_name)))=>ByRow(x->mean(skipmissing(x)))=>char_name)
    else
        # Get all factors within each rating category
        lms_double = combine(groupby(pfs, double_sort)) do sdf
            sdf = unstack(sdf, :date, :pf, ret_col)
            select(sdf, :date, ["1", string(N_sorts)] => ByRow((s, l)-> l-s) => char_name)  # long minus short
        end
        lms_double = unstack(lms_double, :date, double_sort, char_name; renamecols=x->char_name*"_"*string(x))


        # Take equal-weighted average over all double-sorted portfolios
        cols = filter(c -> startswith(string(c), char_name), names(lms_double))
        lms_double[!, char_name] = mean.(skipmissing.(eachrow(((lms_double[!, cols])))))
        lms = select(lms_double, :date, Symbol(char_name))
        select!(lms_double, Not(char_name))
    end

    # Make sure NaN's get converted to missing
    lms[!, char_name] = convert(Vector{Union{Missing, Float64}}, lms[!, char_name])
    replace!(lms[!, char_name], NaN=>missing)

    sort!(lms, [:date])
    sort!(lms_double, [:date])

    if size(lms_double, 2) > 10  # When sorting within a firm don't output all the portfolios
        select!(lms_double, :date, 2:3)
    end

    return lms, lms_double
end

"""
    fmt(from, to, i; leftclosed, rightclosed)

Format function for binned portfolio labels.
Returns string in format "portfolio_number,lower_bound,upper_bound"
"""
fmt(from, to, i; leftclosed, rightclosed) = "$i,$from,$to"

# ============================================================================
# Complete Factor Return Pipeline
# ============================================================================

"""
    compute_factor_returns(df, trace_daily; kwargs...)

Complete pipeline to compute all factor returns from bond data.

# Arguments
- `df`: Main bond dataset with characteristics and returns
- `trace_daily`: Daily TRACE data for liquidity/volatility signals
- `filter`: Description for factor table (default: "No filter - 5 portfolios")
- `N_sorts`: Number of portfolios (default: 5)
- `value_weight`: Use value weighting (default: false)

# Returns
(pfs, factor_returns, factor_table)
- `pfs`: Portfolio-level returns
- `factor_returns`: Long-short factor returns for all characteristics
- `factor_table`: Summary statistics table with alphas and t-stats

# Process
1. Create factor regressors (market, DEF, TERM, FF, VIX, liquidity)
2. Compute rolling signals (liquidity, volatility, VIX beta, market beta, etc.)
3. Compute momentum factor separately
4. Create characteristic-sorted portfolios
5. Compute long-short returns
6. Generate factor summary table

# Note
Requires ~60 months of data for rolling window calculations.
"""
function compute_factor_returns(df, trace_daily; filter="No filter - 5 portfolios", N_sorts=5, value_weight=false)
    # Load and prepare external factors / regressors
    factor_regressors = FactorRegressor(df, trace_daily).factor_regressors
    nrow(dropmissing(factor_regressors)) > 90 || error("Too many missing values in factor_regressors")

    # Characteristics
    @time "Liquidity + Vix: " liq_vol = Pfs.compute_rolling_signals(df, factor_regressors, liq_vol_signals; window=60, min_window=15)
    @time "MKT, VaR etc. :" ranking_betas = Pfs.compute_rolling_signals(df, factor_regressors, rolling_signal_functions; window=36, min_window=24)
    @time "Momentum Factor" mom, pfs_mom, lms_mom = Factors.momentum(df; N_sorts=N_sorts, required_obs="all", value_weight=value_weight)  # Momentum

    df = leftjoin(df, ranking_betas, on=[:date, :cusip])
    df = leftjoin(df, liq_vol, on=[:date, :cusip])

    char_pf_names = [name for name in names(ranking_betas)[3:end]]
    push!(char_pf_names, "amh_liq", "vix")
    pfs, factor_returns = Pfs.compute_characteristic_pfs(df, char_pf_names; N_sorts=N_sorts, value_weight=value_weight, is_cut=false)

    pfs = vcat(pfs, select(pfs_mom, :date, :pf, :pf_6m_ret=>identity=>:ret_ew, :factor); cols=:union)
    dropmissing!(pfs, :factor)

    factor_returns = outerjoin(factor_returns, lms_mom, on=:date)
    sort!(factor_returns, :date)

    factor_table = create_factor_table(factor_returns, factor_regressors; filter=filter)
    return pfs, factor_returns, factor_table
end

"""
    add_factor_name_direction(df; level=:cusip, ice_=false)

Add factor names and directions from Excel metadata file.
Multiplies characteristics by their proper direction (+1 or -1) so that
high values indicate high expected returns.

# Arguments
- `df`: Input DataFrame with characteristics
- `level`: ID column (default: :cusip)
- `ice_`: Whether this is ICE data (excludes Treasury columns)

# Returns
DataFrame with renamed and properly signed characteristics

# Note
Requires "Factor Details - what to lag.xlsx" file with factor metadata.
Creates MV column as -1 * "Market Value*" for proper weighting direction.
"""
function add_factor_name_direction(df; level=:cusip, ice_=false)
    cols = [:ret_exc_lead, :ret_exc_lead2, :ret_eq, :MV_lead, :ret_texc_lead]
    ice_ == true ? cols = cols[1:end-1] : nothing  # Remove ret_texc_lead if ice is true
    factor_details = DataFrame(XLSX.readtable("C:/Users/chris/Dropbox (CBS)/Corporate Bond Replication/Factor Details - what to lag.xlsx", "bond_details"))|>x->dropmissing(x,:var_name)
    df = stack(df, Not([level, :date, cols...]))
    df = leftjoin(df, factor_details[:, [:name, :var_name, :direction]], on=[:variable=>:var_name])
    transform!(df, [:value, :direction]=>ByRow((v,d)->v*d)=>:value, renamecols=false)
    df = unstack(select(df, Not([:variable, :direction])), [level, :date, cols...], :name, :value)
    transform!(df, "Market Value*"=>ByRow(x->x.*-1.)=>:MV)
    select!(df, level, :date, cols..., :MV, :)

    sum(df.MV) > 0. || error("MV cannot be negative")
    return df
end
