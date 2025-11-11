"""
    preprocessing.jl

Preprocessing functions extracted from src/preprocessing/main.jl (Preprocess module)

This module handles:
- Loading and processing FISD bond characteristics
- Bond yield and duration calculations via R's BondValuation package
- Computing bond returns with accrued interest
- Treasury curve calculations
- Processing ICE and Warga data
"""

using CSV
using Parquet
using SASLib
using DataFramesMeta
using Statistics
using StatsBase
using Dates
using ShiftedArrays: lag, lead
using Roots
using RCall
using Distributed

# Include local utilities
# Note: data_loader.jl functions are imported via main.jl (DataLoader module)
# rating_conversions.jl and utils.jl are included in main.jl within this module scope
include("rating_conversions.jl")
include("utils.jl")

# ============================================================================
# FISD PROCESSING
# ============================================================================

"""
    Fisd

Struct to hold all FISD-related DataFrames.
"""
struct Fisd
    mergent:: AbstractDataFrame
    defaults:: AbstractDataFrame
    ratings:: AbstractDataFrame
    amt_out:: AbstractDataFrame
    function Fisd()
        mergent = process_fisd()
        defaults = get_default_dates()
        ratings = process_ratings()
        amt_out = process_amount_outstanding(mergent)
        return new(mergent, defaults, ratings, amt_out)
    end
end

"""
    process_fisd()

Process Mergent FISD bond issue data.
Returns DataFrame with bond characteristics.
"""
function process_fisd()
    mergent = DataFrame(readsas("data/mergent/fisd_issue.sas7bdat")) |> x -> rename(lowercase, x)
    dropmissing!(mergent, [:maturity, :offering_date])

    @rselect!(mergent, :cusip=:complete_cusip, :cusip8=:complete_cusip[1:8], :name=:prospectus_issuer_name,
            :offering_date, :offering_amt, :maturity, :coupon=coalesce(:coupon, 0.),
            :coupon_type, :interest_frequency, :bond_type, :principal=:principal_amt,
            :day_count_basis, :defaulted, :first_interest_date, :last_interest_date, :dated_date, :issue_id, :convertible, :issue_name)

    transform!(mergent, :coupon => ByRow(x->replace_nans(x, replace_val=0.)) => :coupon)
    mergent.first_interest_date .= ifelse.(ismissing.(mergent.first_interest_date), mergent.offering_date, mergent.first_interest_date)
    @rtransform!(mergent, :last_interest_date=coalesce(:last_interest_date, :maturity))
    @rtransform!(mergent, :dated_date=coalesce(:dated_date, :offering_date))

    # Address errors in interest_frequency - delete outside 0-12
    replace!(mergent.interest_frequency, "" => "-1", missing => "-1")
    @transform!(mergent, :interest_frequency = parse.(Int64, :interest_frequency))
    @subset!(mergent, 0 .<= :interest_frequency .<= 12)

    # Handle case where first_interest_date is too far in the future
    @rsubset!(mergent, Dates.value(:first_interest_date-:dated_date)/360 < 2.0*(1/:interest_frequency))
    @rsubset!(mergent, Dates.value(:maturity - :last_interest_date)/360 < 2.0*(1/:interest_frequency))

    # Handle case where last_interest_date is after maturity
    dfv = @rsubset(mergent, :last_interest_date > :maturity; view=true)
    @rtransform!(dfv, :last_interest_date = :maturity)

    # Delete bonds with non-unique 8-digit cusip
    mergent = innerjoin(unique(mergent, :cusip), unique(mergent, :cusip8)[:, [:cusip]], on=:cusip)

    return mergent
end

"""
    get_default_dates()

Get bond default dates from FISD.
"""
function get_default_dates()
    default = @chain begin
        DataFrame(readsas("data/mergent/fisd_defaults.sas7bdat")) |> x -> rename(lowercase, x)
        sort([:default_date])
        combine(groupby(_, :issue_id)) do sdf  # 96 issues default multiple times - use just the first one
            sdf[1, :]
        end
    end
    return default
end

"""
    process_ratings()

Load and process bond credit ratings from FISD.
Returns DataFrame with time-varying ratings.
"""
function process_ratings()
    ratings = @chain begin
        DataFrame(readsas("data/mergent/fisd_ratings.sas7bdat")) |> x -> rename(lowercase, x)
        rename!(:rating_date=>:date)
        @rtransform(:cusip=string(:complete_cusip), :rating_type, :rating=string(:rating))
        @rsubset(:rating_type ∈ ["SPR", "MR"])
        @rsubset(:rating ∈ keys(snp_alphabet_to_numerical) || :rating ∈ keys(moody_alphabet_to_numerical),
                :rating != "NR")
        unique(_,  [:date, :cusip, :rating_type])  # drop duplicates
        unstack(_, [:date, :cusip], :rating_type, :rating)
        transform(:SPR =>  ByRow(passmissing(x -> snp_alphabet_to_numerical[x])) => :SPR_num,
                  :MR =>  ByRow(passmissing(x -> moody_alphabet_to_numerical[x])) => :MR_num)
        transform([:SPR_num, :MR_num] => ByRow((sp, mr) -> mean(skipmissing([sp, mr]))) => :rating_num)
        transform([:SPR_num, :MR_num] => ByRow((sp, mr) -> maximum(skipmissing([sp, mr]))) => :rating_max)
        transform(:rating_num=>ByRow(x->ceil(x)), renamecols=false)
        sort([:cusip, :date])

        @transform(groupby(_, [:cusip]), :date_end = lag(:date, -1))
        @aside replace!(_.date_end, missing => Date("2100-01-01"))
        rename(:MR => :r_mr, :SPR => :r_sp, :MR_num => :n_mr, :SPR_num => :n_sp)
        select(:date => :date_start, :date_end, Not(:date))
    end

    # Find default date
    ratings.default_date_rating = similar(ratings.date_end)
    ratings = combine(groupby(ratings, :cusip)) do sdf
        def_date = findfirst(sdf.rating_max.==22.)
        if def_date != nothing
            sdf[def_date, :default_date_rating] = sdf[def_date, :date_start]
            sdf[def_date, :date_end] = Date("2100-01-01")
            sdf = sdf[1:def_date, :]
        end
        return sdf
    end

    return ratings
end

"""
    process_amount_outstanding()

Process bond amount outstanding data (offering + historical).
"""
function process_amount_outstanding(mergent)
    df = vcat(DataFrame(readsas("data/mergent/fisd_amt_out.sas7bdat")),  # Latest amount outstanding
        DataFrame(readsas("data/mergent/fisd_amt_out_hist.sas7bdat"))) |> unique |> x->rename(lowercase, x)  # Historical amounts
    rename!(df, :complete_cusip => :cusip, :effective_date => :date)

    offering_amt = select(mergent, :issue_id, :cusip, :offering_date, :offering_amt) |> x->rename(x, :offering_date=>:date, :offering_amt=>:amount_outstanding)
    df = vcat(df, offering_amt) |> unique
    @subset!(df, .!isnan.(:amount_outstanding), (:amount_outstanding .>= 1000.) .|| (:amount_outstanding.==0.))
    replace!(df.date, missing => Date("1900-01-01"))
    sort!(df, [:issue_id, :date])

    transform!(groupby(df, :cusip), :amount_outstanding => (x-> x .- lag(x, 1))=> :amount_outstanding_diff)
    df = vcat(@rsubset(df, :amount_outstanding_diff != 0.), @subset(df, ismissing.(:amount_outstanding_diff)))

    # Create start_date, end_date
    sort!(df, [:issue_id, :date])
    @transform!(groupby(df, :cusip), :date_end = lag(:date, -1))
    replace!(df.date_end, missing => Date("2100-01-01"))
    select!(df, :date => :date_start, :date_end, :cusip, :amount_outstanding)
    return df
end


# ============================================================================
# BOND VALUATION (Yield and Duration)
# ============================================================================

"""
    monthdiff(start_date, end_date; as_float=false)

Number of months between start_date and end_date.
"""
function monthdiff(start_date, end_date; as_float=false)
    n_months = length(start_date:Month(1):end_date)
    as_float == true ? n_months = Float64(n_months) : nothing
    return n_months
end

"""
    pv_bond(yield, face_val, coupon, interest_freq, remcoup, time_next_coup; bullet=true)

Calculate present value of a bond given yield.
"""
function pv_bond(yield, face_val, coupon, interest_freq, remcoup, time_next_coup; bullet=true, debug=false, get_pv_cf=false)
    if bullet == true
        return pv_bullet_bond(yield, face_val, coupon, interest_freq, remcoup, time_next_coup)
    end
    c = coupon / interest_freq  # coupon payment
    y = yield/interest_freq

    # Get period to sum over
    t = 1:1:remcoup
    pv_bond_ = c*face_val ./ (1.0+y).^t  # Present value of coupons
    pv_bond_[end] += face_val / (1.0+y)^t[end]  # Present value of face + last coupon
    pv_bond_ = (1+y)^time_next_coup * pv_bond_

    if debug == true
        println("Present value of bond is $(sum(pv_bond_))")
        return [collect(t) pv_bond_]
    elseif get_pv_cf == true  # Return present value of individual cash flows
        return pv_bond_
    else
        return sum(pv_bond_)
    end
end

"""
    pv_bullet_bond(yield, face_val, coupon, interest_freq, remcoup, time_next_coup)

Present value formula for bullet bonds (closed form).
"""
function pv_bullet_bond(yield, face_val, coupon, interest_freq, remcoup, time_next_coup)
    y = yield/interest_freq
    c = coupon / interest_freq
    B0 = face_val * (c/y + (1 - c/y)*(1+y)^-remcoup)  # Price at most recent payment date
    B_t = (1+y)^time_next_coup * B0
end

"""
    bond_duration(yield, face_val, coupon, interest_freq, remcoup, time_next_coup, tmt; bullet=true)

Calculate modified duration of bond.
"""
function bond_duration(yield, face_val, coupon, interest_freq, remcoup, time_next_coup, tmt; bullet=true)
    interest_freq != 0 ? nothing : return (tmt - time_next_coup) / (1+yield)
    bullet == false ? nothing : return bullet_bond_duration(yield, coupon, interest_freq, remcoup, time_next_coup)
    # Get period to sum over
    k = 1:1:remcoup
    t = interest_freq * time_next_coup .+ k .- 1.  # Shift period

    pv_bond_ = pv_bond(yield, face_val, coupon, interest_freq, remcoup, time_next_coup; bullet=false, get_pv_cf=true)

    # Calculate weights
    w = pv_bond_ ./ sum(pv_bond_)

    # Calculate duration
    duration = (w' * k - time_next_coup) / interest_freq
    duration /= (1+yield)

    return duration
end

"""
    bullet_bond_duration(yield, coupon, interest_freq, remcoup, time_next_coup)

Duration formula for bullet bonds (closed form).
"""
function bullet_bond_duration(yield, coupon, interest_freq, remcoup, time_next_coup)
    duration = (1+yield)/yield - (1+yield-remcoup*(yield - coupon)) / (coupon*((1+yield)^remcoup - 1) + yield)
    duration -= time_next_coup
    duration /= interest_freq
    duration /= (1+yield)
end

"""
    yieldp(face_val, coupon, interest_freq, remcoup, time_next_coup, tmt, price; x0=0.05)

Calculate yield-to-maturity for a fixed-rate bond.
Uses root-finding to solve for yield given price.
"""
function yieldp(face_val, coupon, interest_freq, remcoup, time_next_coup, tmt, price; x0=0.05)
    if interest_freq == 0
        return (face_val/price)^(1.0/tmt) - 1.
    else
        try
            target_function = yield -> pv_bond(yield, face_val, coupon, interest_freq, remcoup, time_next_coup; bullet=true) - price
            res = find_zero(target_function, x0)
            res == 0. ? res = find_zero(target_function, x0-0.01) : res  # If zero try different initial value
            res == 0. ? res = find_zero(target_function, x0-0.02) : res
        catch e
            println(e)
            return missing
        end
    end
end

# ============================================================================
# R INTEGRATION FOR BOND VALUATION
# ============================================================================

"""
    bondval(sdf, coupon, interest_freq, mat, offering_date, dated_date, first_interest_date, last_interest_date; face_val=100., DCC=5)

R wrapper to compute bond yield, duration, and accrued interest using BondValuation package.
"""
function bondval(sdf, coupon, interest_freq, mat, offering_date, dated_date, first_interest_date, last_interest_date; face_val=100., DCC=5)
    @rput sdf coupon interest_freq mat offering_date dated_date first_interest_date last_interest_date face_val DCC
    R"""
    dates = withTimeout(suppressWarnings(
        AnnivDates(Coup=coupon, CpY=interest_freq, Em=offering_date, FIAD=dated_date, FIPD=first_interest_date, LIPD=last_interest_date, Mat=mat, RV=100., DCC=5)
        ),
        timeout=5.0, onTimeout="warning"
    )

    df = data.frame(AccrInt=c(), ytm_p_a_=c(), ModDUR_inYears=c(), MacDUR_inYears=c(), Conv_inYears=c())
    for (i in 1:nrow(sdf)){
        res = withTimeout(suppressWarnings(
            BondVal.Yield(CP=sdf$price_eom[i], Coup=coupon, CpY=interest_freq, SETT=sdf$settlement_date[i], Em=offering_date, FIAD=dated_date, FIPD=first_interest_date, LIPD=last_interest_date, Mat=mat, RV=100., DCC=5, AnnivDatesOutput=dates)
            ),
            timeout=1.0, onTimeout="warning"
            )[c(2, 4, 5, 6, 7, 11)]
        res["date"] = as.character(sdf$date[i])

        if (is.list(res)) {  # If result is not a list this prevents an error
            df = rbind(df, res)
          }
    }
    """
    @rget df
end

"""
    bondval_treasury(sdf, ...)

R wrapper for bond valuation using treasury-equivalent pricing.
"""
function bondval_treasury(sdf, coupon, interest_freq, mat, offering_date, dated_date, first_interest_date, last_interest_date; face_val=100., DCC=5)
    @rput sdf coupon interest_freq mat offering_date dated_date first_interest_date last_interest_date face_val DCC
    R"""
    dates = withTimeout(suppressWarnings(
        AnnivDates(Coup=coupon, CpY=interest_freq, Em=offering_date, FIAD=dated_date, FIPD=first_interest_date, LIPD=last_interest_date, Mat=mat, RV=100., DCC=5)
        ),
        timeout=5.0, onTimeout="warning"
    )

    df = data.frame(AccrInt=c(), ytm_p_a_=c(), ModDUR_inYears=c(), MacDUR_inYears=c(), Conv_inYears=c())
    for (i in 1:nrow(sdf)){
        res = withTimeout(suppressWarnings(
            BondVal.Yield(CP=sdf$price_ctreasury[i], Coup=coupon, CpY=interest_freq, SETT=sdf$settlement_date[i], Em=offering_date, FIAD=dated_date, FIPD=first_interest_date, LIPD=last_interest_date, Mat=mat, RV=100., DCC=5, AnnivDatesOutput=dates)
            ),
            timeout=1.0, onTimeout="warning"
            )[c(2, 4, 5, 6, 7, 11)]
        res["date"] = as.character(sdf$date[i])

        if (is.list(res)) {  # If result is not a list this prevents an error
            df = rbind(df, res)
          }
    }
    """
    @rget df
end

"""
    bond_values(gdf; debug=false, treasury=false)

Compute bond yields, duration, and convexity for grouped DataFrame.

This is the main workhorse function that calls R's BondValuation package
for each bond (CUSIP) in the grouped DataFrame. Runs in parallel when
called with pmap().

# Arguments
- `gdf`: GroupedDataFrame grouped by cusip
- `debug`: Print progress messages
- `treasury`: If true, use treasury prices instead of market prices

# Returns
- DataFrame with yield, duration, convexity, accrued interest
- DataFrame with error CUSIPs
"""
function bond_values(gdf; debug=false, treasury=false)
    R"""
    library(BondValuation)
    library(R.utils)
    """

    error_log = []
    res = DataFrame()

    # Loop through each cusip and apply bondval function
    for (idx, (key, sdf)) in enumerate(pairs(gdf))
        if debug == true
            println("$idx out of $(length(gdf)) -- Cusip $(key.cusip) -- $(Dates.format(now(), "H:M:S"))")
        end
        if idx % 50 == 0.
            println("$idx out of $(length(gdf)) done -- $(Dates.format(now(), "H:M:S"))")
        end
        try
            if treasury==false
                params = sdf[1, [:coupon, :interest_frequency, :maturity, :offering_date, :dated_date, :first_interest_date, :last_interest_date]]
                tmp = bondval(@select(sdf, :price_eom, :settlement_date, :date), params...)
            else
                params = sdf[1, [:coupon, :interest_frequency, :maturity, :offering_date, :dated_date, :first_interest_date, :last_interest_date]]
                tmp = bondval_treasury(@select(sdf, :price_ctreasury, :settlement_date, :date), params...)
            end
            tmp.cusip .= sdf.cusip[1]
            dropmissing!(tmp)
            append!(res, tmp)
        catch e
            println(key.cusip, e)
            push!(error_log, [e, key.cusip])
        end
    end
    # Format output data
    error_cusips = [String(error_log[i][2]) for i in 1:length(error_log)] |> x->DataFrame(cusip=x)
    rename!(res, :AccrInt=>:coupacc1, :ytm_p_a_=>:yield, :ModDUR_inYears=>:duration, :MacDUR_inYears=>:mac_duration, :Conv_inYears=>:convexity)
    res.yield /= 100.

    if treasury == true
        rename!(res, :yield=>:yield_rf)
        select!(res, :coupacc1, :yield_rf, :date, :cusip)
    end
    sort!(res, [:cusip, :date])
    res.date = lastdayofmonth.(Date.(res.date, dateformat"yyyy-mm-dd"))
    return res, error_cusips
end

"""
    bond_dates(gdf; debug=false)

Extract coupon payment date schedules for bonds using R's BondValuation package.
"""
function bond_dates(gdf; debug=false)
    R"""
    library(BondValuation)
    library(R.utils)
    """

    error_log = []
    res = DataFrame()
    res1 = DataFrame(RealDates = Union{Missing, Date}[],
                    RD_indexes = Union{Missing, Float64}[],
                    CoupDates = Union{Missing, Date}[],
                    CD_indexes = Union{Missing, Float64}[],
                    AnnivDates = Date[], AD_indexes = Float64[],
                    cusip = String15[])

    # Loop through each cusip
    for (idx, (key, sdf)) in enumerate(pairs(gdf))
        if debug == true
            println("$idx out of $(length(gdf)) -- Cusip $(key.cusip) -- $(Dates.format(now(), "H:M:S"))")
        end
        if idx % 50 == 0.
            println("$idx out of $(length(gdf)) done -- $(Dates.format(now(), "H:M:S"))")
        end
        try
            @rput sdf
            params = sdf[1, [:coupon, :interest_frequency, :maturity, :offering_date, :dated_date, :first_interest_date, :last_interest_date]]

            coupon = params.coupon
            interest_freq = params.interest_frequency
            mat = params.maturity
            offering_date = params.offering_date
            dated_date = params.dated_date
            first_interest_date = params.first_interest_date
            last_interest_date = params.last_interest_date

            @rput coupon interest_freq mat offering_date dated_date first_interest_date last_interest_date

            R"""
            dates = withTimeout(suppressWarnings(
                AnnivDates(Coup=coupon, CpY=interest_freq, Em=offering_date, FIAD=dated_date, FIPD=first_interest_date, LIPD=last_interest_date, Mat=mat, RV=100., DCC=5)
                ),
                timeout=10.0, onTimeout="error"
            )
            """
            @rget dates

            tmp0 = dates
            tmp = tmp0[:PaySched]
            tmp1 = tmp0[:DateVectors]

            tmp.cusip .= sdf.cusip[1]
            tmp1.cusip .= sdf.cusip[1]

            append!(res1, tmp1)
            dropmissing!(tmp)
            append!(res, tmp)

        catch e
            println(key.cusip, e)
            push!(error_log, [e, key.cusip])
        end
    end
    # Format output data
    error_cusips = [String(error_log[i][2]) for i in 1:length(error_log)] |> x->DataFrame(cusip=x)

    sort!(res, [:cusip, :CoupDates])
    sort!(res1, [:cusip, :RealDates])
    return res, res1, error_cusips
end

# ============================================================================
# TREASURY CURVE AND GSW FUNCTIONS
# ============================================================================

"""
    get_gsw_params()

Download GSW (Gürkaynak-Sack-Wright) treasury yield curve parameters from Federal Reserve.
"""
function get_gsw_params()
    # Note: Downloads module is imported in main.jl for the Preprocess module
    res = CSV.read(Downloads.download("https://www.federalreserve.gov/data/yield-curve-tables/feds200628.csv"), DataFrame; header=10,  missingstring=["NA", "-999.99"]) |> x->rename(lowercase, x)
    select!(res, :date, Cols(startswith("beta")), Cols(startswith("tau")))
    replace!(res.tau2, missing=>0.0)
    dropmissing!(res)  # Missing values in all params in various dates such as 1991-03-29

    # Transform to monthly data
    sort!(res, :date)
    @transform!(res, :eom = Dates.lastdayofmonth.(:date))
    res = combine(groupby(res, :eom), Cols(Not(:date)) .=> (x-> x[end]), renamecols=false) |> x->rename(x, "eom" => "date")

    return res
end

"""
    gsw_yield(n, b0, b1, b2, b3, t1, t2; return_price=true)

Calculate n-year treasury yield using GSW parameters.
"""
function gsw_yield(n, b0, b1, b2, b3, t1, t2; return_price=true)
    term1 = b0 + b1 * (1-exp(-n/t1))/(n/t1)
    term2 = b2 * ((1-exp(-n/t1))/(n/t1) - exp(-n/t1))
    if t2 != 0.  # Before 1980 b3 and t2 is not available
        term3 = b3 * ((1-exp(-n/t2))/(n/t2) - exp(-n/t2))
    else
        term3 = 0.
    end
    yield = term1 + term2 + term3
    yield /= 100.  # Get yield in decimals

    if return_price == true
        return exp(-yield * n)
    else
        return yield
    end
end

"""
    price_coupon_treasury(coupon, remcoup, interest_frequency, tmt, time_next_coup, b0, b1, b2, b3, t1, t2; clean_price=true)

Price bond assuming all coupons discounted at treasury rates.
"""
function price_coupon_treasury(coupon, remcoup, interest_frequency, tmt, time_next_coup,  b0, b1, b2, b3, t1, t2; debug=false, clean_price=true)
    coupon = coupon / interest_frequency
    if interest_frequency != 0
        n = interest_frequency
        time_next_coup == 0. ? t_start = 1/interest_frequency : t_start = time_next_coup
        t_end = remcoup/n
        t_end < t_start ? t_end = t_end + t_start : nothing  # Special case where first coupon starts e.g. 10 years from now
        t = t_start:1/n:t_end
        p_rf = gsw_yield.(t,  b0, b1, b2, b3, t1, t2; return_price=true)
        p_rf[1:end-1] *= coupon
        p_rf[end] *= (100. + coupon)

        if clean_price == true
            # For zero coupons, the first coupon equals accrued interest
            p_rf[1] *= t_start * interest_frequency
        end

        if debug == true
            return p_rf
        else
            return sum(p_rf)
        end
    elseif interest_frequency == 0
        p_rf = gsw_yield(tmt,  b0, b1, b2, b3, t1, t2; return_price=true) * 100.
    end
end

"""
    add_treasury_returns(df)

Compute treasury-equivalent returns for bonds.
"""
function add_treasury_returns(df)
    df = calendar_fill(df, date_col=:date)
    sort!(df, [:cusip, :date])
    transform!(groupby(df, :cusip), [:price_ctreasury] .=> lag)
    @rtransform!(df, :ret_teom = (:price_ctreasury + :coupamt + :coupacc) / (:price_ctreasury_lag + :coupacc_lag) - 1.)
    df.ret_texc .= df.ret_eom .- df.ret_teom

    df = dropmissing(df, [:price_eom, :MV])
    subset!(df, :ret_texc .=> ByRow(x->!(x isa Number && isnan(x))))
    transform!(groupby(df, :cusip), :ret_texc => lead)
    return df
end

# ============================================================================
# BOND RETURNS COMPUTATION
# ============================================================================




""" Aggregate daily prices into monthly by taking the last observed price in the last 7 days of a given month """
function agg_daily_trace_to_month(trace_daily;version_="", interpolate=false, liq=false, write_=false)
    version_ in ["", "2016"] ? 0 : error(""" version_ must either be an empty string "" for the full dataset or be equal to "2016" """)
    trade_dates = load_trade_dates(with_day_diff=false)  # compressed trade_dates
    trade_dates_diff = load_trade_dates(with_day_diff=true)[:, Not(:eom)]  # trade_dates with differences

    trace_month = @chain trace_daily begin
        @rtransform(:eom = Dates.lastdayofmonth(:date))
        @rtransform(:max_days_month = day(:eom) )  # Last day in month - e.g. 28 in February
        innerjoin(trade_dates, on=:eom)  # Add all trading dates
    end


    if interpolate != true  # Find prices in first 5 and last 5 tradings days of a month and combine them
        # Separate monthly prices into those in beginning and end of month
        tm_bom = subset(trace_month, AsTable([:date, :first_trading_date]) => ByRow(x -> x.date in x.first_trading_date) )
        tm_end = subset(trace_month, AsTable([:date, :last_trading_date]) => ByRow(x -> x.date in x.last_trading_date) )
        tm_bom = @combine(groupby(tm_bom, [:cusip, :eom]), :price_bom = :price[1])
        tm_end = @combine(groupby(tm_end, [:cusip, :eom]), :price_eom=:price[end], :volume=:volume[end], :trade_date=:date[end], :last_trade_date=:last_trade_date_val[end])
        trace_month = outerjoin(tm_end, tm_bom, on=[:eom, :cusip], makeunique=true) |> x -> dropmissing(x, :price_eom)   # Combine bom and eom prices by month
    else
        # Find first and last price in a month - combine them and then shift and interpolate missing date
        if liq == true  # Lin et al (2011) uses last trade prices from intraday data so it has to be handled separately
            trace_month = @combine(groupby(trace_month, [:eom, :cusip]), :price_eom = :price[end], :price_bom = :price_first[1], 
                                                                        :trade_date=:date[end], :last_trade_date=:last_trade_date_val[end], :trade_date_bom=:date[1])
        else
        trace_month = @combine(groupby(trace_month, [:eom, :cusip]), :price_eom = :price[end], :price_bom = :price[1], 
                                                                    :trade_date=:date[end], :last_trade_date=:last_trade_date_val[end], :trade_date_bom=:date[1])
        end
        trace_month = calendar_fill(trace_month; date_col=:eom)  # Fill in missing months
        @transform!(groupby(trace_month, :cusip), :price_bom_lead = lag(:price_bom, -1), :trade_date_bom_lead=lag(:trade_date_bom, -1))  # Lead bom price and dates
        @transform! trace_month @byrow @passmissing :price_eom = :price_eom + (:price_bom_lead-:price_eom) * Dates.value(:eom-:trade_date) / Dates.value(:trade_date_bom_lead-:trade_date)
        trace_month = dropmissing(trace_month, :price_eom)
    end

    rename!(trace_month, :eom => :date)
    leftjoin!(trace_month, trade_dates_diff, on=[:last_trade_date => :date])
    sort!(trace_month, [:cusip, :date])

    println("Number of monthly prices in millions: $(nrow(trace_month) / 1e6)")
    return trace_month
end